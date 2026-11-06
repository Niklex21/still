import { Action, ActionPanel, Clipboard, closeMainWindow, Icon, List, open, showToast, Toast } from "@raycast/api";
import { useEffect, useState } from "react";
import { pathToFileURL } from "node:url";
import { Capture, captureDate, imagePath, markHandled, markReviewed, matches, passesFilter, semanticIDs, readLibrary } from "./library";

export default function Command() {
  const [items, setItems] = useState<Capture[]>([]);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("all");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [ranked, setRanked] = useState<string[] | null>(null);
  const [searching, setSearching] = useState(false);
  useEffect(() => {
    setRanked(null);
    if (!query.trim()) { setSearching(false); return; }
    const controller = new AbortController(); setSearching(true);
    const timer = setTimeout(() => { void semanticIDs(query, controller.signal).then(setRanked).catch(() => {}).finally(() => { if (!controller.signal.aborted) setSearching(false); }); }, 220);
    return () => { clearTimeout(timer); controller.abort(); };
  }, [query, items]);
  const visible = (ranked ? ranked.map((id) => items.find((item) => item.id === id)).filter((item): item is Capture => !!item) : items.filter((item) => matches(item, query))).filter((item) => passesFilter(item, filter));
  const [selected, setSelected] = useState<string | null>(null);
  async function reload() {
    try { const next = await readLibrary(); setItems((old) => JSON.stringify(old) === JSON.stringify(next) ? old : next); setError(""); }
    catch (e) { setError(String(e)); }
    finally { setLoading(false); }
  }
  useEffect(() => { void reload(); const timer = setInterval(() => void reload(), 2000); return () => clearInterval(timer); }, []);
  useEffect(() => {
    const item = items.find((item) => item.id === selected);
    if (!item || item.reviewedAt != null || !item.onShelf) return;
    const timer = setTimeout(() => { void markReviewed(item.id).catch(() => {}); }, 800);
    return () => clearTimeout(timer);
  }, [selected, items]);
  async function launch(url: string) {
    try { await open(url); await closeMainWindow(); }
    catch (e) { await showToast({ style: Toast.Style.Failure, title: "Could not open Still", message: String(e) }); }
  }
  return <List isLoading={loading || searching} isShowingDetail filtering={false} onSelectionChange={setSelected} onSearchTextChange={setQuery} searchBarPlaceholder="Search images, names, and text…"
    searchBarAccessory={<List.Dropdown tooltip="Filter captures" onChange={setFilter}><List.Dropdown.Item value="all" title="All Captures" /><List.Dropdown.Item value="shelf" title="On Shelf" /><List.Dropdown.Item value="favorites" title="Favorites" /><List.Dropdown.Item value="today" title="Last 24 Hours" /><List.Dropdown.Item value="week" title="Last 7 Days" /><List.Dropdown.Item value="text" title="Contains Text" />{[...new Set(items.map((item) => item.metadata?.application).filter((name): name is string => !!name))].sort().map((name) => <List.Dropdown.Item key={name} value={`app:${name}`} title={name} />)}</List.Dropdown>}>
    <List.EmptyView icon={Icon.Camera} title={error ? "Could not read the library" : items.length ? "No screenshots match" : "Your screenshot library is empty"} description={error || "Capture or import an image in Still to get started."} actions={<ActionPanel><Action title="Open Still" onAction={() => launch("still://search")} /></ActionPanel>} />
    {visible.map((item) => <List.Item key={item.id} id={item.id} title={item.title} icon={{ source: imagePath(item) }} accessories={[...(item.favorite ? [{ icon: Icon.Star }] : []), ...(item.onShelf ? [{ icon: Icon.Tray }] : [])]}
      detail={<List.Item.Detail markdown={`![Screenshot](${pathToFileURL(imagePath(item)).href})`} metadata={<List.Item.Detail.Metadata><List.Item.Detail.Metadata.Label title="Dimensions" text={`${item.width} × ${item.height}`} /><List.Item.Detail.Metadata.Label title="Captured" text={captureDate(item).toLocaleString()} />{item.metadata?.application && <List.Item.Detail.Metadata.Label title="Application" text={item.metadata.application} />}{item.metadata?.sourceURL && <List.Item.Detail.Metadata.Link title="Source" text={item.metadata.sourceURL} target={item.metadata.sourceURL} />}{item.metadata?.notes && <List.Item.Detail.Metadata.Label title="Notes" text={item.metadata.notes} />}<List.Item.Detail.Metadata.Separator />{item.visualIndex?.version === 1 && item.visualIndex.revision === item.revision && <List.Item.Detail.Metadata.Label title="Image description" text={item.visualIndex.summary} />}<List.Item.Detail.Metadata.Label title="Recognized text" text={item.text ? item.text.slice(0, 1000) : "No text detected"} /></List.Item.Detail.Metadata>} />}
      actions={<ActionPanel>
        <Action title="Copy Image" icon={Icon.Clipboard} onAction={async () => { try { await Clipboard.copy({ file: imagePath(item) }); await markHandled(item.id).catch(() => {}); await showToast({ style: Toast.Style.Success, title: "Image copied" }); await closeMainWindow(); } catch (e) { await showToast({ style: Toast.Style.Failure, title: "Could not copy image", message: String(e) }); } }} />
        <Action title="Prepare for Upload" icon={Icon.Upload} shortcut={{ modifiers: ["cmd"], key: "u" }} onAction={() => launch(`still://upload?id=${encodeURIComponent(item.id)}`)} />
        <Action title="Select Text in Image" icon={Icon.Text} shortcut={{ modifiers: ["cmd"], key: "t" }} onAction={() => launch(`still://text?id=${encodeURIComponent(item.id)}`)} />
        <Action title="Export or Resize" icon={Icon.Download} shortcut={{ modifiers: ["cmd", "shift"], key: "e" }} onAction={() => launch(`still://export?id=${encodeURIComponent(item.id)}`)} />
        <Action title="Show Description" icon={Icon.Info} shortcut={{ modifiers: ["cmd"], key: "i" }} onAction={() => launch(`still://describe?id=${encodeURIComponent(item.id)}`)} />
        <Action title="Annotate in Still" icon={Icon.Pencil} shortcut={{ modifiers: ["cmd"], key: "e" }} onAction={() => launch(`still://edit?id=${encodeURIComponent(item.id)}`)} />
        <Action title="Add to Shelf" icon={Icon.Tray} shortcut={{ modifiers: ["cmd"], key: "s" }} onAction={() => launch(`still://shelf?id=${encodeURIComponent(item.id)}`)} />
        <Action.CopyToClipboard title="Copy Recognized Text" content={item.text} shortcut={{ modifiers: ["cmd", "shift"], key: "c" }} onCopy={() => { void markHandled(item.id).catch(() => {}); }} />
        <Action.ShowInFinder path={imagePath(item)} onShow={() => { void markReviewed(item.id).catch(() => {}); }} />
        <Action.OpenWith path={imagePath(item)} onOpen={() => { void markReviewed(item.id).catch(() => {}); }} />
        <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["cmd"], key: "r" }} onAction={reload} />
      </ActionPanel>} />)}
  </List>;
}
