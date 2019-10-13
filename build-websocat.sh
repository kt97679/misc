#!/bin/bash

rustup update
cd ~/git/websocat
git pull
cargo build --release --features=ssl
cargo build --target=armv7-unknown-linux-gnueabihf --release
strip target/armv7-unknown-linux-gnueabihf/release/websocat
strip target/release/websocat
