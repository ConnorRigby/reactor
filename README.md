# NervesReactor

This is a proof of concept for hot code *reloading* remote Erlang nodes in development.
This is **not** a tool for deploying hot code *upgrades* to production environments.
The primary use case for me, the author of this POC, is to get development reload capabilities
on remote Nerves devices akin to how Dart's hot code reload works.

## What's working/features

* reloading entire applications
* reloading individual modules
* automatically bootstraps nodes, syncing the local "primary" node's application tree over to the
  remote node.
* no runtime dependency on the remote node
* no dependencies for the "host" node other than Elixir.
  * considering using Erlang too allow for hot code loading of Elixir
    applications onto pure Erlang nodes. I was thoughtful of this, but haven't
    confirmed if it works.

## What's next/todos

My end goal is to have support for Visual Studio Code's
[Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/).
The road to this will include a few steps that i've yet to ponder as of writing this.

* Bundling this otp application an extension
  * use [Bakeware](https://github.com/bake-bake-bake/bakeware)
  * see how [vscode-elixir-ls](https://github.com/elixir-lsp/vscode-elixir-ls)
  * just run a mix task on the machine?
* Connecting to remote devices via VS-Code's "ssh" thing?
  * this is a stretch goal. i have no idea what this even means.
* Pretty sure DAP needs an HTTP (ish?) server. Loading cowboy into this app is simple,
  but would complicate things for sure.
* `Mix.env()` and `Mix.target()` are respected, but I still need to verify this works as expected.
  * `priv` dir is not synced correctly. it works on same arch/libc machines, but the cross compilation problem exits.
  * I think this is a simple fix, but I have a concern regarding `-mode embedded`. There is a TODO in the code.
  * `priv` is important for native C code. One problem I see with this is cross compilation.
    I think Nerves will work out of the box because of how we hijacked the C compiler, but using the Reactor
    to reload c code on remote erlang nodes using different libc will have issues. Bakeware shares the same issue.
* Check if Phoenix views recompile. Specifically with `eex` and `leex`. Current hot code reloads have issues with
  this because the templates are compiled into the module, and when you reload the file, the path is different.
  I've not spent a lot of time investigating this, but I think it's an easy fix.
* Node discovery. I don't want to tackle this problem directly, but an "adapter" patern could be implemented.
  * example: Nerves devices broadcast using `mdns`, so an adapter could be created to automatically detect them
  * example: libcluster does some black magic to detect devices, so an adapter could be created.
* No reason for this to be `nerves` specific.
  * I knew this from the start, I just like the name `Nerves Reactor` so much that I forgot about it.

## FAQ and noteworth information

* Hasn't this been done before?
  * [i](https://github.com/kentaro/mix_tasks_upload_hotswap)
  * [dont](https://embedded-elixir.com/post/2018-12-10-using-distribution-to-test-hardware/)
  * [think](https://gist.github.com/ConnorRigby/c98d9112459ac6b3020d9c2bc13140b4)
  * [so](https://github.com/Tubitv/ex_loader)
* Similar concept: [erl_boot_server](https://erlang.org/doc/man/erl_boot_server.html)
  * My first idea was to use this, but it only works for bootstraping fresh nodes.
    This means that for Nerves, we'd have to start a second instance of beam, or
    implement some other way of hijacking the current beam process.
