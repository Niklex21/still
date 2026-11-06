import { homedir } from "node:os";
import { join, basename } from "node:path";
import { readFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

export interface Capture {
  id: string;
  title: string;
  filename: string;
  text: string;
  createdAt: number;
  width: number;
  height: number;
  onShelf: boolean;
  favorite: boolean;
  revision: number;
  reviewedAt?: number;
  metadata?: { application?: string; bundleIdentifier?: string; windowTitle?: string; sourceURL?: string; kind?: string; notes: string; tags: string[] };
  visualIndex?: { version: number; revision: number; summary: string; keywords: string[] };
}
export async function markReviewed(id: string): Promise<void> {
  // Let the running app serialize index updates; never race it with a JSON write.
  await promisify(execFile)("/usr/bin/open", ["-g", `still://review?id=${encodeURIComponent(id)}`]);
}
export async function markHandled(id: string): Promise<void> {
  await promisify(execFile)("/usr/bin/open", ["-g", `still://consume?id=${encodeURIComponent(id)}`]);
}
export const libraryRoot = join(homedir(), "Library", "Application Support", "Still");
export function imagePath(item: Capture): string {
  // Never resolve a path outside the app's image directory from index contents.
  return join(libraryRoot, "Images", basename(item.filename));
}
export function matches(item: Capture, query: string): boolean {
  const normalize = (value: string) => value.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLocaleLowerCase();
  const visual = item.visualIndex?.version === 1 && item.visualIndex.revision === item.revision ? item.visualIndex : undefined;
  const haystack = normalize(`${item.title} ${item.text} ${visual?.summary ?? ""} ${visual?.keywords.join(" ") ?? ""} ${item.metadata?.application ?? ""} ${item.metadata?.windowTitle ?? ""} ${item.metadata?.sourceURL ?? ""} ${item.metadata?.kind ?? ""} ${item.metadata?.notes ?? ""} ${item.metadata?.tags.join(" ") ?? ""}`);
  return normalize(query).trim().split(/\s+/).every((word) => haystack.includes(word));
}
export async function readLibrary(): Promise<Capture[]> {
  try {
    const data = JSON.parse(await readFile(join(libraryRoot, "library.json"), "utf8"));
    if (data.version !== 1 || !Array.isArray(data.captures)) throw new Error("Unsupported Still library format");
    return data.captures;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
}
export function captureDate(item: Capture): Date {
  // Swift's JSONEncoder uses seconds since 2001-01-01.
  return new Date((item.createdAt + 978307200) * 1000);
}

export async function semanticIDs(query: string, signal?: AbortSignal): Promise<string[]> {
  const { stdout } = await promisify(execFile)("/Applications/Still.app/Contents/MacOS/Still", ["--search-json", query], { timeout: 15000, maxBuffer: 4 * 1024 * 1024, signal });
  const ids: unknown = JSON.parse(stdout);
  if (!Array.isArray(ids) || !ids.every((id) => typeof id === "string")) throw new Error("Invalid search response");
  return ids;
}
export function passesFilter(item: Capture, filter: string, now = new Date()): boolean {
  if (filter === "shelf") return item.onShelf;
  if (filter === "favorites") return item.favorite;
  if (filter === "text") return !!item.text;
  if (filter.startsWith("app:")) return item.metadata?.application === filter.slice(4);
  if (filter === "week" || filter === "today") return captureDate(item).getTime() >= now.getTime() - (filter === "week" ? 7 : 1) * 86400000;
  return true;
}
