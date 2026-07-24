# todo

A small, persistent to-do CLI in a single Zig file. It is the interactive
companion to the guide's [File-Backed To-Do Store](https://www.ziglang.in/how-to/todo-store/)
recipe: the recipe runs one fixed scenario so CI can verify its output, while
this takes real commands and keeps your list in `~/.todos.db` between runs.

The storage design is the same: fixed-size `extern struct` records, so item N
lives at a known byte offset and any one item is read or updated in place with
positional I/O, no rewrite of the whole file.

## Build

Requires Zig master (same as the guide).

```sh
zig build-exe todo.zig -femit-bin=todo
```

That produces a `todo` binary in the current directory. Put it on your `PATH`
to use it anywhere.

## Use

```sh
./todo add buy milk
./todo add write the docs
./todo add ship the guide
./todo                     # or: ./todo list
  1  [ ]  buy milk
  2  [ ]  write the docs
  3  [ ]  ship the guide

./todo done 1
./todo toggle 3
./todo rm 2
./todo                     # 2 is gone; 1 and 3 are done
  1  [x]  buy milk
  3  [x]  ship the guide

./todo clear               # delete everything
```

Commands: `add <text>`, `list` (the default), `done <id>`, `toggle <id>`,
`rm <id>`, `clear`. Removing an item leaves a tombstone so the remaining ids
never shift.

## Where the data lives

In `~/.todos.db` (it falls back to the current directory if `$HOME` is unset).
Delete that file, or run `todo clear`, to start over. Each record is a fixed
number of bytes, so the file is literally an array of items on disk.
