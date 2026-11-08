# qory's hello example

`examples/hello/` is the folder `examples/hello` of https://github.com/qoryai/qory at
commit fd0a7da85ca956469a0113daeb4b44f938d82019, unchanged: the output of
`git archive fd0a7da85ca956469a0113daeb4b44f938d82019 examples/hello`.

The built-in harness (`Apiary.Harnesses.Builtin`) extends that folder on the branch
`main`. `test/apiary/harnesses/builtin_compose_test.exs` composes the built-in harness on
top of this copy with a qory binary. To compose against a later commit, replace the folder
with that commit's and write that commit in this file.
