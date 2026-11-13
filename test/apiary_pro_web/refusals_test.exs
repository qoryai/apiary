defmodule ApiaryProWeb.RefusalsTest do
  # Every change the pages offer, the core's and the edition's, sent through the web layer by
  # someone who may not make it: the core's rows (`ApiaryWeb.RefusalsRows`) again, under
  # the edition, and the edition's (`ApiaryProWeb.RefusalsRows`): a member of another
  # workspace or one removed from it, an operator's people, a client's, and the instance's
  # admins, on the edition's pages and on the core's. Sent by `ApiaryWeb.RefusalsCase`,
  # which fails for any action of `Apiary.Access` that changes something and has no row. Not
  # async: its tests write through the suite's instance organisation, committed once outside
  # the sandbox, whose row and owners they lock (docs/conventions.md, Tests). The world is
  # made once for the module; each row is sent inside a savepoint of it.
  use ApiaryWeb.RefusalsCase,
    rows: [ApiaryWeb.RefusalsRows, ApiaryProWeb.RefusalsRows],
    cast: :module

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # A workspace's set-up is finished: the Overview opens, and the rows reach it.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
end
