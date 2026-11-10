defmodule ApiaryWeb.RunLive.ShowFixerTest do
  @moduledoc """
  Who fixes a cause that lies with a run's machine type, on the run page
  (`ApiaryWeb.RunLive.Show`), by reader: an image of the type that is not in its
  registry, or whose registry returned 401 or 403, 429, or could not be reached, under
  Pull the images, and a type that no pool offer fits, under Queue the run. An instance admin reads the instance admin's line. An organisation member reads
  "Contact support with run …" in plain text, as the run page's other lines for the
  instance's pool, with the pool's admin for a type no offer of a workspace's pool fits,
  and the page has no word "instance": an organisation's people never see that word, and
  "support" is how they reach the instance admins.
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

  @image_admin "An instance admin sets an image that exists in Instance settings › Machine types, then runs the work item again."
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

  # A run started in the image of a type with the key `fixer-ui`, which no other test uses,
  # whose pull ended `image_missing`, or with the image code `reason`.
  defp image_missing!(ctx, reason \\ "image_missing")

  defp image_missing!(%{scope: scope, key: key}, reason) do
    type =
      Repo.insert!(%MachineType{
        key: "fixer-ui",
        name: "Fixer UI",
        vcpus: 2,
        memory_mib: 4096,
        disk_gib: 30,
        arch: "amd64",
        image: @image
      })

    %{run: run} =
      handed_over_fixture(scope, key, %{
        wall: "docker",
        image: @image,
        configured_image: @image,
        started_image_from: "top_level",
        started_image: @image,
        configured_image_from_type: true,
        configured_image_machine_type_id: type.id
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

  # A run its pool's record gave `@image`, not a machine type, whose pull ended with the
  # image code `reason`.
  defp image_not_of_type!(%{scope: scope, key: key}, reason) do
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

  describe "an image of the run's type that is not in its registry" do
    test "an instance admin reads the instance admin's line", ctx do
      run = image_missing!(ctx)
      view = :instance_admin |> reader(ctx) |> open(ctx.scope, run)

      assert text(view, "#prepare-machine-fix") == @image_admin
      refute has_element?(view, "#prepare-machine-fix a")
    end

    test "an organisation member reads Contact support with the run, as plain text", ctx do
      run = image_missing!(ctx)
      view = :member |> reader(ctx) |> open(ctx.scope, run)

      assert text(view, "#prepare-machine-fix") == "Contact support with run #{run.public_id}."
      refute has_element?(view, "#prepare-machine-fix a")
      refute page_text(view) =~ ~r/instance/i
    end
  end

  # The image as the instance admin's line shows it: its digest cut to 12 digits.
  @short String.slice(@image, 0, 44) <> "…"

  # Forager's other image codes, on a pool of the run's workspace: what happened, for every
  # reader, then the instance admin's fix, its cause and the image, or the member's line
  # with the run.
  @image_codes [
    {"image_access_denied",
     "Pull the images failed: access to the image of the machine type Fixer UI (fixer-ui) was denied.",
     "An instance admin gives the run's registry credential read access to the image, or sets another image in Instance settings › Machine types. If the workspace's policy blocks the registry, a workspace admin allows it on the workspace's Policy page. The registry returned 401 or 403 for #{@short}, or the run's proxy returned 403 because of the policy. On Docker Hub, 401 also means that the repository does not exist.",
     "Contact support with run "},
    {"image_rate_limited",
     "Pull the images failed: a rate limit stopped the requests for the image of the machine type Fixer UI (fixer-ui).",
     "An instance admin runs the work item again once the registry's rate limit resets, or the admin of build-pool raises the gateway's run limits. The registry or the run's proxy returned 429 Too Many Requests for #{@short}.",
     "Run the work item again later. If it fails again, contact support with run "},
    {"image_registry_unreachable",
     "Pull the images failed: no connection to the image's registry, for the machine type Fixer UI (fixer-ui).",
     "An instance admin checks that the registry's host name resolves, that the registry is running and that its certificate is valid, then runs the work item again. The connection to the registry for #{@short} failed or took longer than 30 seconds.",
     "Contact support with run "}
  ]

  for {code, what, admin, member} <- @image_codes do
    describe "an image of the run's type whose pull ended #{code}" do
      @code code
      @what what
      @admin admin
      @member member

      test "an instance admin reads what happened, then the fix, its cause and the image", ctx do
        run = image_missing!(ctx, @code)
        view = :instance_admin |> reader(ctx) |> open(ctx.scope, run)

        assert text(view, "#run-why .q-run-why-t") == @what
        assert text(view, "#prepare-machine-cause") == @what
        assert has_element?(view, "#prepare-machine-cause .font-mono", "fixer-ui")
        assert text(view, "#prepare-machine-fix") == @admin
        refute has_element?(view, "#prepare-machine-fix a")
      end

      test "an organisation member reads what happened, then the line with the run", ctx do
        run = image_missing!(ctx, @code)
        view = :member |> reader(ctx) |> open(ctx.scope, run)

        assert text(view, "#run-why .q-run-why-t") == @what
        assert text(view, "#prepare-machine-cause") == @what
        assert text(view, "#prepare-machine-fix") == @member <> "#{run.public_id}."
        refute has_element?(view, "#prepare-machine-fix a")
        refute page_text(view) =~ ~r/instance/i
      end

      test "a run whose image is not its type's reads the step's line, with no fix line",
           ctx do
        run = image_not_of_type!(ctx, @code)
        view = :instance_admin |> reader(ctx) |> open(ctx.scope, run)

        refute page_text(view) =~ @what
        refute has_element?(view, "#prepare-machine-fix")
      end
    end
  end

  describe "an image of the run's type whose pull ended image_rate_limited, on Qory Pool" do
    @describetag :instance_pool

    test "an instance admin reads that an instance admin raises the gateway's run limits",
         ctx do
      run = image_missing!(ctx, "image_rate_limited")
      view = :instance_admin |> reader(ctx) |> open(ctx.scope, run)

      assert text(view, "#prepare-machine-fix") ==
               "An instance admin runs the work item again once the registry's rate limit resets, or raises the gateway's run limits. The registry or the run's proxy returned 429 Too Many Requests for #{@short}."
    end

    test "an organisation member reads the line to run it again later, with the run", ctx do
      run = image_missing!(ctx, "image_rate_limited")
      view = :member |> reader(ctx) |> open(ctx.scope, run)

      assert text(view, "#prepare-machine-fix") ==
               "Run the work item again later. If it fails again, contact support with run #{run.public_id}."

      refute page_text(view) =~ ~r/instance/i
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
