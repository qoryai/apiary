defmodule ApiaryWeb.RunLive.ShowFixerTest do
  @moduledoc """
  Who fixes a cause that lies with a run's machine type, on the run page
  (`ApiaryWeb.RunLive.Show`), by reader: a type that no pool offer fits, under Queue the
  run. An instance admin reads the instance admin's line. An organisation member reads
  "Contact support with run …" in plain text, as the run page's other lines for the
  instance's pool, with the pool's admin for a type no offer of a workspace's pool fits,
  and the page has no word "instance": an organisation's people never see that word, and
  "support" is how they reach the instance admins. A pull of a run's image that failed
  with one of Forager's image codes is the step's line, with no line of who fixes it: a
  machine type has no image.
  """
  # Not async: the support address is the node's, and an instance admin's grant acts on
  # the instance's organisation, which every test shares. The address is set, so a test
  # shows that the member's line has no link even where one could be made.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [handed_over_fixture: 3, workspace_gateway!: 1]
  import Apiary.MachineTypesFixtures, only: [spec: 0, spec: 1, with_offers: 2]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures, only: [member_fixture: 1]
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Organisations, Repo}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.MachineTypes.MachineType
  alias Apiary.Runs.Run

  @moduletag needs: :factory

  @image "ghcr.io/acme/agent-fixer@sha256:" <> String.duplicate("6c3e", 16)
  @support "support@example.com"

  @fit_admin "An instance admin makes the type fit an offer in Instance settings › Machine types, or the admin of build-pool adds an offer that fits."

  setup :register_and_log_in_user

  setup %{scope: scope} = ctx do
    Application.put_env(:apiary, :support_address, @support)
    on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)

    if ctx[:instance_pool] do
      # No pool of the workspace: the instance's pool, Qory Pool, serves it.
      installed_key_fixture(instance_gateway_fixture(), allow_secrets: true)
      pool = instance_pool_fixture()
      %{access_key: key} = installed_key_fixture(pool)
      %{pool: pool, key: key}
    else
      workspace_gateway!(scope)
      pool = pool_fixture(scope, name: "build-pool")
      %{access_key: key} = enrolled_key_fixture(scope, pool)
      %{pool: pool, key: key}
    end
  end

  # The connection of the reader: the scope's person made an instance admin, or a member
  # of the scope's workspace.
  defp reader(:instance_admin, %{conn: conn, scope: scope}) do
    {:ok, _grant} = Organisations.grant_instance_admin(scope.user)
    conn
  end

  defp reader(:member, %{scope: scope}) do
    %{user: user} = member_fixture(scope)
    log_in_user(build_conn(), user)
  end

  defp open(conn, scope, %Run{number: number}) do
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{number}")
    render_async(view)
    view
  end

  # The words of the page, without its markup.
  defp page_text(view), do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  # A run its pool's record gave `@image`, whose pull ended with the image code `reason`.
  defp image_failed!(%{scope: scope, key: key}, reason) do
    %{run: run} =
      handed_over_fixture(scope, key, %{
        wall: "docker",
        image: @image,
        configured_image: @image,
        started_image_from: "top_level",
        started_image: @image
      })

    event_fixture(run, 9, "run.step_started", %{"step" => 1, "name" => @image, "kind" => "image"})

    event_fixture(run, 10, "run.step_exited", %{
      "step" => 1,
      "state" => "failed",
      "exit_code" => -1,
      "duration_ms" => 900
    })

    event_fixture(run, 11, "run.exited", %{
      "state" => "failed",
      "reason" => reason,
      "exit_code" => -1
    })

    {:ok, run} = Apiary.Runs.Projector.project(run)
    run
  end

  # A queued run on a type with the key `fixer-large`, which no other test uses, that no
  # offer of the context's pool fits.
  defp no_fit!(%{scope: scope, pool: pool}) do
    Repo.insert!(%MachineType{
      key: "fixer-large",
      name: "Fixer large",
      vcpus: 4,
      memory_mib: 16_384,
      disk_gib: 60,
      arch: "amd64"
    })

    work_item = work_item_fixture(scope, %{title: "Test the cart on a large screen"})
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()

    Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^queued.id),
      set: [state: :resolved, origin: :file, workflow: "explore-a-ticket"]
    )

    Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id),
      set: [machine_type: "fixer-large", machine_spec: spec(), machine_type_was_default: false]
    )

    with_offers(pool, [spec(%{arch: "arm64"})])
    Repo.one!(from r in Run, where: r.dispatch_run_id == ^queued.id)
  end

  for code <- ~w(image_missing image_access_denied image_rate_limited image_registry_unreachable) do
    describe "a pull of the run's image that ended #{code}" do
      @code code

      test "reads the step's line, with no line of who fixes it", ctx do
        run = image_failed!(ctx, @code)
        view = :instance_admin |> reader(ctx) |> open(ctx.scope, run)

        assert text(view, "#prepare-machine-cause") =~ "Pull the images failed"
        refute page_text(view) =~ "machine type"
        refute has_element?(view, "#prepare-machine-fix")
      end
    end
  end

  describe "a type that no pool offer fits" do
    test "an instance admin reads the instance admin's line, with the pool's admin", ctx do
      run = no_fit!(ctx)
      view = :instance_admin |> reader(ctx) |> open(ctx.scope, run)

      assert text(view, "#prepare-machine-why") =~
               "no pool offers a machine that fits Fixer large"

      assert text(view, "#prepare-machine-why-fix") == @fit_admin
      refute has_element?(view, "#prepare-machine-why-fix a")
    end

    test "an organisation member reads Contact support with the run, or the pool's admin, as plain text",
         ctx do
      run = no_fit!(ctx)
      view = :member |> reader(ctx) |> open(ctx.scope, run)

      assert text(view, "#prepare-machine-why") =~
               "no pool offers a machine that fits Fixer large"

      assert text(view, "#prepare-machine-why-fix") ==
               "Contact support with run #{run.public_id}, or ask the admin of build-pool to add an offer that fits."

      refute has_element?(view, "#prepare-machine-why-fix a")
      refute page_text(view) =~ ~r/instance/i
    end

    @tag :instance_pool
    test "on a workspace that only the instance's pool serves, an instance admin reads the line with Qory Pool",
         ctx do
      run = no_fit!(ctx)
      view = :instance_admin |> reader(ctx) |> open(ctx.scope, run)

      assert text(view, "#prepare-machine-why-fix") ==
               "An instance admin makes the type fit an offer in Instance settings › Machine types, or the admin of Qory Pool adds an offer that fits."
    end

    @tag :instance_pool
    test "on a workspace that only the instance's pool serves, an organisation member reads Contact support with the run alone",
         ctx do
      run = no_fit!(ctx)
      view = :member |> reader(ctx) |> open(ctx.scope, run)

      assert text(view, "#prepare-machine-why") =~
               "no pool offers a machine that fits Fixer large"

      assert text(view, "#prepare-machine-why-fix") ==
               "Contact support with run #{run.public_id}."

      refute page_text(view) =~ ~r/instance|Qory Pool/i
    end
  end
end
