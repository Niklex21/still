.PHONY: build test install dmg
build:
	./scripts/build.sh
test:
	./scripts/check.sh
install:
	./scripts/install.sh
dmg:
	./scripts/package-dmg.sh
