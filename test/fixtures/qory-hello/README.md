# qory's hello example

`examples/hello/` is the folder `examples/hello` of https://github.com/qoryai/qory at
commit fd0a7da85ca956469a0113daeb4b44f938d82019, unchanged: the output of
`git archive fd0a7da85ca956469a0113daeb4b44f938d82019 examples/hello`.

The built-in harness (`Apiary.Harnesses.Builtin`) extends that folder at that commit.
`test/apiary/harnesses/builtin_compose_test.exs` composes the built-in harness on top of
it with a qory binary. When the built-in harness moves to another commit, replace the
folder with that commit's and write that commit in this file.
