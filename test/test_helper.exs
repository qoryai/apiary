# The tests tagged :contract replay the fixtures of the server contract, which live in
# the runner's repository (`Apiary.ContractFixtures.contract_dir/0` says where they are
# looked for). Without them the tests are excluded and one line says so; CI sets
# CONTRACT_FIXTURES_REQUIRED=1, which makes their absence a failure.
exclude =
  cond do
    Apiary.ContractFixtures.contract_dir() ->
      []

    System.get_env("CONTRACT_FIXTURES_REQUIRED") == "1" ->
      raise "CONTRACT_FIXTURES_REQUIRED=1 and the runner's contract directory is not there: " <>
              "set RUNNER_CONTRACT_DIR to contracts/runner/v1 of a qoryai/runner checkout"

    true ->
      IO.puts(
        "Excluding the :contract tests: no runner contract directory " <>
          "(set RUNNER_CONTRACT_DIR to contracts/runner/v1 of a qoryai/runner checkout)"
      )

      [:contract]
  end

# A LiveView's async assigns and a PubSub message arrive in milliseconds on an idle machine
# and not within the default 100 ms under a full, parallel suite: `render_async` and
# `assert_receive` wait up to five seconds, and return as soon as there is something.
ExUnit.start(exclude: exclude, assert_receive_timeout: 5_000)
Ecto.Adapters.SQL.Sandbox.mode(Apiary.Repo, :manual)
