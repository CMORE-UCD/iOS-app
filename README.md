# Installation

## Install git lfs
```
brew install git-lfs
git lfs install
```

## Setup the repo
```
git clone https://github.com/AlundorZhu/CMORE-app.git
cd CMORE-app/
git lfs pull
open CMORE.xcodeproj
```

# Potential Bug
Only works with `1080x1920` since `camerasettings.resolution` is used everywhere...
