# The tests tagged :contract replay the fixtures of the server contract, which live in
# Forager's repository at the commit in .forager-contract-ref
# (`Apiary.ContractFixtures.contract_dir/0` says where they are looked for). Without them
# the tests are excluded and one line says so; CI sets CONTRACT_FIXTURES_REQUIRED=1, which
# makes their absence a failure.
exclude =
  cond do
    Apiary.ContractFixtures.contract_dir() ->
      []

    System.get_env("CONTRACT_FIXTURES_REQUIRED") == "1" ->
      raise "CONTRACT_FIXTURES_REQUIRED=1 and Forager's contract directory is not there: " <>
              "set FORAGER_CONTRACT_DIR to contracts/forager/v1 of a qoryai/forager checkout"

    true ->
      IO.puts(
        "Excluding the :contract tests: no Forager contract directory " <>
          "(set FORAGER_CONTRACT_DIR to contracts/forager/v1 of a qoryai/forager checkout, " <>
          "or fetch #{Apiary.ContractFixtures.pinned_ref()} into ../../forager/main)"
      )

      [:contract]
  end

# A LiveView's async assigns and a PubSub message arrive in milliseconds on an idle machine
# and not within the default 100 ms under a full, parallel suite: `render_async` and
# `assert_receive` wait up to five seconds, and return as soon as there is something.
# The suite with QORY_FEATURES unset or blank, CI's "every feature", runs with every
# feature: the opt-in ones too (`Apiary.Features.opt_in/0`), which an instance launched so
# leaves off.
if String.trim(Application.get_env(:apiary, :features_setting) || "") == "" do
  Application.put_env(:apiary, :features, Apiary.Features.all())
end

# A test tagged `needs: feature` exercises that feature; the suite runs in CI under more
# than one QORY_FEATURES, and a run without the feature leaves such tests out.
#
# A test tagged `with_features:` runs under the features it names, whatever the suite's
# (`Apiary.DataCase.setup_features/1`), and so passes or fails alike under each: it runs
# where the suite has every feature, and a run with fewer leaves it out.
off = Apiary.Features.all() -- Apiary.Features.enabled()

exclude =
  exclude ++
    for(feature <- off, do: {:needs, feature}) ++ if(off == [], do: [], else: [:with_features])

# The tests tagged :load measure the receiver under a gateway's backlog, for long and outside
# the sandbox: they run only when asked for, with `mix test --only load`.
exclude = exclude ++ [:load]

ExUnit.start(exclude: exclude, assert_receive_timeout: 5_000)

# The instance has had its first sign-up, committed before the sandbox takes over: a
# sign-up in a test is a later one (`Apiary.OrganisationsFixtures.ensure_instance_organisation!/0`).
Apiary.OrganisationsFixtures.ensure_instance_organisation!()

Ecto.Adapters.SQL.Sandbox.mode(Apiary.Repo, :manual)
