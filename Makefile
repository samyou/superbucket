.PHONY: build app run test clean

build:
	swift build

app:
	./scripts/build-app.sh

run: app
	open build/SuperBucket.app

test:
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi; swift test

clean:
	rm -rf .build build
