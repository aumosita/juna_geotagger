---
description: How to build, commit, and push changes to Juna Geotagger
---

After making code changes to the Juna Geotagger project:

// turbo-all

1. Build with swift build to check compilation:
```
swift build 2>&1
```

2. Build .app bundle with xcodebuild:
```
xcodebuild -project JunaGeotagger.xcodeproj -scheme JunaGeotagger -configuration Release build 2>&1 | tail -3
```

3. Stage all changes and commit with a descriptive message:
```
git add -A && git commit -m "<descriptive message>"
```

4. Push to GitHub:
```
git push
```
