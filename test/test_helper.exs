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

# A test tagged :a11_item3 (Workspace settings › Model) or :a11_item5 (the set-up's Model
# step) saves a model choice of the workspace with no tiers, and a save of the workspace
# needs every tier. ExUnit skips each such test until its page saves the tiers.
exclude = exclude ++ [:a11_item3, :a11_item5]

# The features, the tags left out beside these, ExUnit, the instance and the sandbox:
# `Apiary.TestSetup.start!/1` says what each is.
Apiary.TestSetup.start!(exclude: exclude)
