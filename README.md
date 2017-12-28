# vEditor

![App Icon](https://raw.github.com/qvacua/vimr/master/resources/vimr-app-icon.png)

[Download](https://github.com/qvacua/vimr/releases) • <http://vimr.org>

[![Bountysource](https://www.bountysource.com/badge/team?team_id=933&style=raised)](https://www.bountysource.com/teams/vimr?utm_source=VimR%20%E2%80%94%20Vim%20Refined&utm_medium=shield&utm_campaign=raised) [![Chat at https://gitter.im/vimr/vimr](https://badges.gitter.im/vimr/vimr.svg)](https://gitter.im/vimr/vimr?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge) [![Travis builds](https://travis-ci.org/qvacua/vimr.svg?branch=develop)](https://travis-ci.org/qvacua/vimr) [![Stories in Ready](https://badge.waffle.io/qvacua/vimr.svg?label=ready&title=Ready)](http://waffle.io/qvacua/vimr)

## About
A preservative fork of [vimR](https://github.com/qvacua/vimr), one of my
favorite Neovim IDEs.


## Building

Update software:

```bash
git clone git@github.com:Vvkmnn/vimR.git
cd vimR
git submodule init
git submodule update
```

Build via [Swift](https://github.com/qvacua/vimr#swiftneovim), Xcode 9, and
Homebrew:

```bash
xcode-select --install # install the Xcode command line tools, if you haven't already
brew bundle

./bin/build_vimr.sh # VimR.app will be placed in build/Build/Products/Release/
```

## Issues

[Feature Issues](https://github.com/qvacua/vimr/issues) & [Current Status](https://waffle.io/qvacua/vimr).

