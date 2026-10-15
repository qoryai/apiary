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
          "(set FORAGER_CONTRACT_DIR to contracts/forager/v1 of a qoryai/forager checkout)"
      )

      [:contract]
  end

# The tests tagged :integrations_contract read the integration contract, which lives in
# the repository qoryai/integrations at the commit in .integrations-contract-ref
# (`Apiary.IntegrationsContract.contract_dir/0`), the same way: excluded with one line
# when it is not there, a failure when CONTRACT_FIXTURES_REQUIRED=1.
exclude =
  cond do
    Apiary.IntegrationsContract.contract_dir() ->
      exclude

    System.get_env("CONTRACT_FIXTURES_REQUIRED") == "1" ->
      raise "CONTRACT_FIXTURES_REQUIRED=1 and the integration contract's directory is not " <>
              "there: set INTEGRATIONS_CONTRACT_DIR to contracts/integration/v1 of a " <>
              "qoryai/integrations checkout"

    true ->
      IO.puts(
        "Excluding the :integrations_contract tests: no integration contract directory " <>
          "(set INTEGRATIONS_CONTRACT_DIR to contracts/integration/v1 of a " <>
          "qoryai/integrations checkout)"
      )

      [:integrations_contract | exclude]
  end

# The features, the tags left out beside these, ExUnit, the instance and the sandbox:
# `Apiary.TestSetup.start!/1` says what each is.
Apiary.TestSetup.start!(exclude: exclude)
