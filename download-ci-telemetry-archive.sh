#!/usr/bin/env dash

archive_dir="ci-telemetry-archive"
mkdir -p "$archive_dir"
gh run view 35459761178 --log > "$archive_dir"/run-35459761178-initial.log
gh run view 35460471844 --log > "$archive_dir"/run-35460471844-cold-cache.log
gh run view 35461703995 --log > "$archive_dir"/run-35461703995-cached.log
