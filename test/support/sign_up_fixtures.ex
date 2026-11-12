defmodule ApiaryPro.SignUpFixtures do
  @moduledoc """
  Who may sign up, for one test (`ApiaryPro.SignUp`). The suite's environment opens
  sign-up to organisations (config/test.exs), which wins over the saved row: a test that
  needs other kinds open unsets both variables for the rest of the test, and saves the row
  inside its sandbox, which rolls it back. The variables are the whole node's, so such a
  test is not async.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Apiary.Repo

  @variables [
    organisations: :sign_up_organisations_setting,
    operators: :sign_up_operators_setting
  ]

  @doc """
  put_variables/1 sets `SIGNUP_ORGANISATIONS` and `SIGNUP_OPERATORS` as
  `config/runtime.exs` would have read them, `organisations:` and `operators:`, nil for
  not set, for the rest of the test, and puts the suite's back after it.
  """
  @spec put_variables(keyword) :: :ok
  def put_variables(values) do
    for {name, key} <- @variables do
      previous = Application.fetch_env(:apiary, key)
      Application.put_env(:apiary, key, Keyword.get(values, name))

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end)
    end

    :ok
  end

  @doc "unset_variables/0 is neither variable set, for the rest of the test."
  @spec unset_variables() :: :ok
  def unset_variables, do: put_variables([])

  @doc """
  open!/1 opens `kinds` to a later sign-up, for the rest of the test: both variables
  unset, and the row saved with `kinds` open and the others closed, as an instance admin
  would save it, without the trail's entry.
  """
  @spec open!([ApiaryPro.Tenants.kind()]) :: :ok
  def open!(kinds) when is_list(kinds) do
    unset_variables()

    setting = &if(&1 in kinds, do: "open", else: "closed")

    Repo.insert_all(
      "instance_sign_up",
      [
        %{
          id: true,
          organisations: setting.(:organisation),
          operators: setting.(:operator),
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: {:replace, [:organisations, :operators, :updated_at]},
      conflict_target: :id
    )

    :ok
  end
end
