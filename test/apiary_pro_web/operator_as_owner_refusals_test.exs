defmodule ApiaryProWeb.OperatorAsOwnerRefusalsTest do
  # The changes the pages offer in a client while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`), sent through the web layer by someone
  # who may not make them: `ApiaryProWeb.OperatorAsOwnerRefusalsRows`, in the world of the
  # core's and the edition's rows, sent by `ApiaryWeb.RefusalsCase.assert_row/3`. The module does
  # not `use` the case: its check that every action has a row runs in
  # `ApiaryProWeb.RefusalsTest`.
  # Not async: its tests write through the suite's instance organisation, committed once
  # outside the sandbox, whose row and owners they lock (docs/conventions.md, Tests).
  use ApiaryWeb.ConnCase, async: false

  @moduletag with_features: Apiary.Features.all()

  @modules [
    ApiaryWeb.RefusalsRows,
    ApiaryProWeb.RefusalsRows,
    ApiaryProWeb.OperatorAsOwnerRefusalsRows
  ]

  # The world, made once for the module with the flag off, which its last rows module
  # turns on (`Apiary.DataCase.setup_module_sandbox/2`); each row runs inside a savepoint.
  setup_all context do
    Apiary.DataCase.setup_module_sandbox(context, fn ->
      ApiaryPro.Flags.put_transfers(true)
      ApiaryPro.Flags.put_operator_infrastructure(false)
      %{refusals_world: ApiaryWeb.RefusalsCase.world(@modules)}
    end)
  end

  # The flags live in the process that set them: each test sets them as the world left them.
  setup do
    ApiaryPro.Flags.put_transfers(true)
    ApiaryPro.Flags.put_operator_infrastructure(true)
  end

  for {row, n} <-
        Enum.with_index(
          ApiaryWeb.RefusalsCase.rows([ApiaryProWeb.OperatorAsOwnerRefusalsRows]),
          1
        ) do
    @tag refusal: row, capture_log: row.answer == :not_found_at_mount
    test "#{n}. #{row.action}: #{row.actor} sends #{row.event} on #{row.page}, #{row.answer}",
         ctx do
      ApiaryWeb.RefusalsCase.assert_row(ctx.refusal, @modules, ctx.refusals_world)
    end
  end

  test "every row names an action, an actor of the world, and a known answer" do
    ApiaryWeb.RefusalsCase.assert_rows(@modules, :all)
  end
end
