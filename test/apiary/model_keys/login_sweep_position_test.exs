defmodule Apiary.ModelKeys.LoginSweepPositionTest do
  # `Apiary.ModelKeys.Login.sweep_due/1` goes on, in each pass, where the last pass of the
  # node stopped, so that 22 logins of an organisation that `Apiary.Access` does not allow
  # cannot hide the login of an allowed one. The position lives in the node
  # (`:persistent_term`), so these tests are not async and turn it on, and clean it up.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.ModelKeys.Login

  @moduletag needs: [:factory, :secrets]

  @day 86_400
  @position {Login, :sweep_cursor}

  defmodule RefusesOrganisation do
    # An edition that does not allow `model_key.refresh` in the organisations named
    # "Refused ...".
    @moduledoc false
    def check(_scope, :"model_key.refresh", %Apiary.Organisations.Organisation{
          name: "Refused" <> _
        }),
        do: {:error, :forbidden}

    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  setup do
    previous = Application.get_env(:apiary, Login)
    Application.put_env(:apiary, Login, sweep_position: true)
    :persistent_term.erase(@position)

    on_exit(fn ->
      Application.put_env(:apiary, Login, previous)
      :persistent_term.erase(@position)
    end)

    :ok = Apiary.Edition.put_test_stub(RefusesOrganisation)
    %{scope: scope} = sign_up_fixture()
    %{scope: refused} = sign_up_fixture(%{organisation_name: "Refused Org"})

    # 22 logins of the refused organisation, 30 days old, and one of the allowed one, 8 days.
    for name <- ["One", "Two"] do
      keys = for n <- 1..11, do: %{value_id: "k#{n}", value: login_paste(tag: "#{name}-#{n}")}

      {:ok, _provider} =
        Connections.create_provider(refused, %{
          provider: "openai-subscription",
          name: name,
          keys: keys
        })
    end

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: login_paste(tag: "allowed")}]
      })

    Repo.update_all(from(l in Login, where: l.organisation_id == ^refused.organisation.id),
      set: [signed_in_at: DateTime.add(DateTime.utc_now(), -30 * @day)]
    )

    Repo.update_all(from(l in Login, where: l.organisation_id == ^scope.organisation.id),
      set: [signed_in_at: DateTime.add(DateTime.utc_now(), -8 * @day)]
    )

    %{allowed: key_value!(provider, "main").id}
  end

  defp pass(limit) do
    capture_log(fn -> send(self(), {:swept, Login.sweep_due(limit)}) end)
  end

  test "the second pass reaches the allowed login, and a pass to the end starts again", ctx do
    # The first pass reads 20 pages of one login, all refused, and stops.
    log = pass(1)
    assert_received {:swept, []}
    assert log =~ "stopped after 20 logins read in 20 pages"
    assert :persistent_term.get(@position, nil) != nil

    pass(1)
    assert_received {:swept, [{_provider, id}]}
    assert id == ctx.allowed

    # Nothing is left after the allowed login: the position is dropped.
    pass(1)
    assert_received {:swept, []}
    assert :persistent_term.get(@position, :none) == :none

    # The next pass starts at the oldest login again.
    log = pass(1)
    assert_received {:swept, []}
    assert log =~ "stopped after 20 logins read in 20 pages"
  end
end
