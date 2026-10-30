defmodule ApiaryWeb.TargetLive.EnvironmentTest do
  @moduledoc """
  The Environment card of a target's Overview (`ApiaryWeb.TargetLive.Show`), for a reader
  of the workspace's work items: for each node pool, the image a run of the target starts
  in (`Apiary.Environments.image_for/2`), in mono, its digest shortened and the whole
  reference its title, when it was built and its commit, or that runs use the pool's
  default image and why, or that runs wait until the target's environment image is
  built, or that they use the image set in the workspace's policy;
  whether a build runs or waits; the last build's failure by its cause, never a starter's
  reason; one line where no pool serves the workspace or the target names no environment.
  Rebuild, for whoever may ask for a build, where the target names an environment and a
  pool serves the workspace, with its toasts and its Activity line; no card where the
  reader is not shown the feature.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [gateway_for!: 2, registry_image: 2]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.{Dispatches, Environments, Policy, Repo, Targets}
  alias Apiary.Environments.Record
  alias Apiary.Policy.{Render, RunConfiguration}

  @moduletag needs: :factory

  @system "code.example.com"
  @path "acme/shop"
  @digest "3a1b9c2d4e5f" <> String.duplicate("0", 52)
  @image "registry.example.com:5000/acme/shop-env@sha256:" <> @digest
  @other_image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("7e0a", 16)
  @naming ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":["api.example"]},"image":"with-docker"}})

  setup :register_and_log_in_user

  setup %{scope: scope} do
    started_run(scope, %{"forge" => @system, "repository" => @path})
    shop = Targets.get(scope, @system, @path)
    %{shop: shop, path: workspace_path(scope, "/targets/#{shop.public_id}")}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 2_000)
    view
  end

  # A collection assigned to the workspace with the target, made after the pools it is
  # given, so nothing is queued for it.
  defp collection(scope, attrs \\ []) do
    collection_fixture(
      scope,
      Keyword.merge(
        [
          external_ref: "SHOP",
          target_system: @system,
          target_path: @path,
          environment_ref: "env-1"
        ],
        attrs
      )
    )
  end

  # A record of the pool and the collection; `@image` stands for the organisation's image
  # at its place in the registry (`own/1`), the only image a run is given.
  defp record!(scope, pool, collection, attrs) do
    attrs =
      Map.update(Map.new(attrs), :image, nil, fn
        @image -> own(scope)
        image -> image
      end)

    Repo.insert!(
      struct(
        Record,
        Map.merge(
          %{
            organisation_id: scope.organisation.id,
            workspace_id: scope.workspace.id,
            pool_id: pool.id,
            source_collection_id: collection.id
          },
          Map.new(attrs)
        )
      )
    )
  end

  # The organisation's image of the target with `@digest`, under its place in the registry.
  defp own(scope), do: registry_image(scope.organisation.id, @digest)

  defp built(at, attrs \\ []) do
    Map.merge(
      %{
        image: @image,
        size: 734_003_200,
        commit: "9c1e4a7b2d5f8e0a3c6b9d2f5a8c1e4b7d0a3f6c",
        built_at: at,
        reported_ref: "env-1",
        built_ref: "env-1",
        built_target_system: @system,
        built_target_path: @path
      },
      Map.new(attrs)
    )
  end

  # A version of the workspace's baseline whose policy sets an image, after the newest one.
  # The workspace must have a baseline already.
  defp set_policy_image!(scope) do
    {:ok, baseline} = Policy.current_configuration(scope, nil)

    Repo.insert!(%RunConfiguration{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      version: baseline.version + 1,
      document: @naming,
      digest: Render.digest(@naming),
      rendered_at: DateTime.utc_now()
    })
  end

  defp pool_id(pool), do: "#target-environment-pool-#{pool.id}"

  # The words of the element `selector` shows, without its attributes.
  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  describe "the card" do
    test "in the main column, its heading, a line for each pool with its name",
         %{conn: conn, scope: scope, path: path} do
      mac = pool_fixture(scope, name: "mac-pool")
      linux = pool_fixture(scope, name: "linux-pool")
      collection(scope)
      view = open(conn, path)

      assert has_element?(view, "#target-overview .q-tgt-ov-main > section#target-environment")
      assert has_element?(view, "#target-environment-h", "Environment")
      assert has_element?(view, "#{pool_id(mac)} h3", "mac-pool")
      assert has_element?(view, "#{pool_id(linux)} h3", "linux-pool")
    end

    test "no pool: one line", %{conn: conn, scope: scope, path: path} do
      collection(scope)
      view = open(conn, path)

      assert has_element?(
               view,
               "#target-environment-no-pool",
               "No pool serves the workspace of this repository."
             )

      refute has_element?(view, "#target-environment-pools")
      refute has_element?(view, "#target-environment-rebuild")
    end

    test "no environment: one line, also for a target no collection of the workspace has",
         %{conn: conn, scope: scope, path: path} do
      pool_fixture(scope)
      view = open(conn, path)

      assert has_element?(
               view,
               "#target-environment-none",
               "This repository has no environment set, so runs use each pool's default image."
             )

      collection(scope, environment_ref: nil)
      view = open(conn, path)
      assert has_element?(view, "#target-environment-none")
      refute has_element?(view, "#target-environment-pools")
      refute has_element?(view, "#target-environment-rebuild")
    end

    test "no image yet: runs wait for the build, and a build waiting",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope, name: "linux-pool")
      shop = collection(scope)
      view = open(conn, path)

      assert has_element?(
               view,
               "#{pool_id(pool)}-held",
               "Runs wait until this repository's environment image is built."
             )

      refute has_element?(view, "#{pool_id(pool)}-waiting")

      {:ok, {:ok, _run}} =
        Repo.transact(fn -> {:ok, Dispatches.queue_prebuild(shop, pool, "env-1")} end)

      view = open(conn, path)

      assert has_element?(
               view,
               "#{pool_id(pool)}-held",
               "Runs wait until this repository's environment image is built."
             )

      assert has_element?(view, "#{pool_id(pool)}-waiting", "A build is waiting.")
      refute has_element?(view, "#{pool_id(pool)}-running")
    end

    # A claim takes a prebuild only on an instance with a registry.
    @tag needs: [:factory, :registry]
    test "a build running", %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope)
      shop = collection(scope)

      {:ok, {:ok, _run}} =
        Repo.transact(fn -> {:ok, Dispatches.queue_prebuild(shop, pool, "env-1")} end)

      _gateway = gateway_for!(scope, pool)
      %{access_key: key} = enrolled_key_fixture(scope, pool)
      {:ok, _claimed} = Dispatches.claim(key, Dispatches.now())
      view = open(conn, path)

      assert has_element?(view, "#{pool_id(pool)}-running", "A build is running.")
      refute has_element?(view, "#{pool_id(pool)}-waiting")
    end

    @tag needs: [:factory, :registry]
    test "an image stored outside the organisation's place in the registry: the pool's default image, no image or built time",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope, name: "mac-pool")
      shop = collection(scope)
      foreign = "registry.other.example/acme/shop-env@sha256:" <> @digest
      record!(scope, pool, shop, built(DateTime.utc_now(), image: foreign))
      view = open(conn, path)

      assert has_element?(view, "#{pool_id(pool)}-default", "The pool's default image.")
      refute has_element?(view, "#{pool_id(pool)}-image")
      refute has_element?(view, "#{pool_id(pool)}-built")
      refute has_element?(view, "#{pool_id(pool)}-held")
      refute render(view) =~ "registry.other.example"
    end

    test "the image: in mono, its digest shortened, the whole reference its title, when built, from its commit",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope, name: "mac-pool")
      shop = collection(scope)
      at = DateTime.utc_now()
      record!(scope, pool, shop, built(at))
      view = open(conn, path)
      [name, _digest] = String.split(own(scope), "@sha256:")

      assert has_element?(
               view,
               ~s(#{pool_id(pool)}-image.q-tgt-env-image[title="#{own(scope)}"]),
               name <> "@sha256:3a1b9c2d4e5f…"
             )

      refute text(view, "#{pool_id(pool)}-image") =~ @digest

      assert has_element?(
               view,
               "#{pool_id(pool)}-built",
               "built #{ApiaryWeb.Format.datetime(at, year: false)}"
             )

      assert has_element?(
               view,
               "#{pool_id(pool)}-built time[datetime='#{DateTime.to_iso8601(at)}']"
             )

      assert has_element?(view, "#{pool_id(pool)}-commit", "from 9c1e4a7")
      refute text(view, "#{pool_id(pool)}-commit") =~ "9c1e4a7b"
      refute has_element?(view, "#{pool_id(pool)}-default")
      refute has_element?(view, "#{pool_id(pool)}-failure")
    end

    # The image is pinned by its digest, which the table's rule holds to the contract's
    # pattern; the commit is any text of 1 to 200 characters.
    test "the commit a pool reported is written as text", %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope)
      shop = collection(scope)
      record!(scope, pool, shop, built(DateTime.utc_now(), commit: "<i>9c1e4a7</i>"))
      view = open(conn, path)

      assert has_element?(view, "#{pool_id(pool)}-commit", "from <i>9c1e")
      refute has_element?(view, "#{pool_id(pool)}-commit i")
    end

    test "the commit a pool reported is cleaned: a bidirectional override dropped, a control character marked, inside <bdi>",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope)
      shop = collection(scope)
      record!(scope, pool, shop, built(DateTime.utc_now(), commit: "\u202E\a9c1e4a7b2d5f"))
      view = open(conn, path)
      html = view |> element("#{pool_id(pool)}-commit") |> render()

      refute html =~ "\u202E"
      refute html =~ "\a"
      # The mark is one of the seven characters the line shows.
      assert has_element?(view, "#{pool_id(pool)}-commit .font-mono > bdi", "\uFFFD9c1e4a")
      assert text(view, "#{pool_id(pool)}-commit") =~ "from \uFFFD9c1e4a"
      refute text(view, "#{pool_id(pool)}-commit") =~ "\uFFFD9c1e4a7"
    end

    test "the last build's failure, by its cause, and never the reason a starter gave",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope)
      shop = collection(scope)

      record =
        record!(scope, pool, shop, %{
          failure_cause: :released,
          failure_reason: "The job could not pull its base image.",
          failed_at: DateTime.utc_now()
        })

      view = open(conn, path)
      assert has_element?(view, "#{pool_id(pool)}-failure", "The last build was given back.")
      refute render(view) =~ "could not pull"

      for {cause, words} <- [
            lost: "The last build was lost before it finished.",
            failed: "The last build failed.",
            timed_out: "The last build failed: it ran past 1 hour and 15 minutes."
          ] do
        record
        |> Ecto.Changeset.change(failure_cause: cause, failure_reason: nil)
        |> Repo.update!()

        assert has_element?(open(conn, path), "#{pool_id(pool)}-failure", words)
      end
    end

    test "a failure after the last good image shows beside it",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope)
      shop = collection(scope)
      at = DateTime.add(DateTime.utc_now(), -600, :second)

      record!(
        scope,
        pool,
        shop,
        built(at, failure_cause: :timed_out, failed_at: DateTime.add(at, 60, :second))
      )

      view = open(conn, path)
      assert has_element?(view, "#{pool_id(pool)}-image")

      assert has_element?(
               view,
               "#{pool_id(pool)}-failure",
               "The last build failed: it ran past 1 hour and 15 minutes."
             )
    end

    test "two collections of the target: a build of one after the other's failure leaves no failure line; a failure after the build shows",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope)
      first = collection(scope)
      second = collection(scope, external_ref: "SHOP2", environment_ref: "env-2")
      earlier = DateTime.add(DateTime.utc_now(), -600, :second)
      later = DateTime.add(earlier, 300, :second)

      failed =
        record!(scope, pool, first, %{failure_cause: :timed_out, failed_at: earlier})

      image =
        record!(scope, pool, second, built(later, reported_ref: "env-2", built_ref: "env-2"))

      view = open(conn, path)
      assert has_element?(view, "#{pool_id(pool)}-image")
      refute has_element?(view, "#{pool_id(pool)}-failure")

      failed |> Ecto.Changeset.change(failed_at: later) |> Repo.update!()
      image |> Ecto.Changeset.change(built_at: earlier) |> Repo.update!()
      view = open(conn, path)
      assert has_element?(view, "#{pool_id(pool)}-image")

      assert has_element?(
               view,
               "#{pool_id(pool)}-failure",
               "The last build failed: it ran past 1 hour and 15 minutes."
             )
    end

    test "an image of a ref the collection no longer has: runs wait for the new build, and the page shows no image",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope)
      shop = collection(scope, environment_ref: "env-2")
      record!(scope, pool, shop, built(DateTime.utc_now()))
      view = open(conn, path)

      assert text(view, "#{pool_id(pool)}-held") =~
               "Runs wait until this repository's environment image is built."

      refute has_element?(view, "#{pool_id(pool)}-image")
      refute has_element?(view, "#{pool_id(pool)}-built")
      refute has_element?(view, "#{pool_id(pool)}-commit")
      refute has_element?(view, "#{pool_id(pool)}-default")
    end

    test "a pool's name is written as text", %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope, name: "<b>mac</b>-pool")
      collection(scope)
      view = open(conn, path)

      assert has_element?(view, "#{pool_id(pool)} h3", "<b>mac</b>-pool")
      refute has_element?(view, "#{pool_id(pool)} h3 b")
    end

    test "retired: the target names no environment any more",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope)
      shop = collection(scope, environment_ref: nil)

      record!(
        scope,
        pool,
        shop,
        built(DateTime.utc_now())
      )

      view = open(conn, path)

      assert has_element?(
               view,
               "#{pool_id(pool)}-retired",
               "Runs use the pool's default image: this repository no longer has an environment set."
             )

      refute has_element?(view, "#{pool_id(pool)}-image")
      refute has_element?(view, "#target-environment-none")
      refute has_element?(view, "#target-environment-rebuild")
    end

    test "built for another target: runs wait until the target is built",
         %{conn: conn, scope: scope, path: path} do
      pool = pool_fixture(scope)
      shop = collection(scope)

      record!(
        scope,
        pool,
        shop,
        built(DateTime.utc_now(), built_target_system: @system, built_target_path: "acme/old")
      )

      view = open(conn, path)

      assert has_element?(
               view,
               "#{pool_id(pool)}-held",
               "Runs wait until this repository's environment image is built."
             )

      refute has_element?(view, "#{pool_id(pool)}-image")
      refute has_element?(view, "#{pool_id(pool)}-commit")
    end

    # A run is given only an image under its organisation's place in the registry.
    @tag needs: [:factory, :registry]
    test "two collections whose records differ in built target: the image a run of the target starts in, never the newer build for another target",
         %{conn: conn, scope: scope, shop: shop, path: path} do
      pool = pool_fixture(scope)
      first = collection(scope)
      second = collection(scope, external_ref: "SHOP2", environment_ref: "env-2")
      earlier = DateTime.add(DateTime.utc_now(), -600, :second)
      later = DateTime.add(earlier, 300, :second)
      image = registry_image(scope.organisation.id, @digest)

      for_shop = record!(scope, pool, first, built(earlier, image: image))

      record!(
        scope,
        pool,
        second,
        built(later, image: @other_image, built_target_path: "acme/old")
      )

      assert Environments.image_for(pool, shop) == image
      view = open(conn, path)
      assert has_element?(view, "#{pool_id(pool)}-image[title='#{image}']")
      refute has_element?(view, "#{pool_id(pool)}-held")

      for_shop |> Ecto.Changeset.change(built_target_path: "acme/old") |> Repo.update!()
      assert Environments.image_for(pool, shop) == nil
      view = open(conn, path)
      refute has_element?(view, "#{pool_id(pool)}-image")

      assert has_element?(
               view,
               "#{pool_id(pool)}-held",
               "Runs wait until this repository's environment image is built."
             )
    end

    @tag needs: [:factory, :registry]
    test "a build of an environment_ref its collection no longer has serves no run, even when it is the newest build for the target",
         %{scope: scope, shop: shop} do
      pool = pool_fixture(scope)
      first = collection(scope)
      second = collection(scope, external_ref: "SHOP2", environment_ref: "env-2")
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -600, :second)
      image = registry_image(scope.organisation.id, @digest)

      stale = record!(scope, pool, first, built(now, image: @other_image, built_ref: "env-0"))
      record!(scope, pool, second, built(earlier, built_ref: "env-2", image: image))

      assert Environments.image_for(pool, shop) == image

      Repo.delete_all(from r in Record, where: r.id != ^stale.id and r.pool_id == ^pool.id)
      assert Environments.image_for(pool, shop) == nil
    end

    test "the workspace's policy sets an image: each pool says runs use it, in place of the prebuilt image",
         %{conn: conn, scope: scope, shop: shop, path: path} do
      mac = pool_fixture(scope, name: "mac-pool")
      linux = pool_fixture(scope, name: "linux-pool")
      shop_collection = collection(scope)
      record!(scope, mac, shop_collection, built(DateTime.utc_now()))
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})

      view = open(conn, path)
      assert has_element?(view, "#{pool_id(mac)}-image")
      refute has_element?(view, "#{pool_id(mac)}-policy")

      set_policy_image!(scope)
      view = open(conn, path)

      for pool <- [mac, linux] do
        assert has_element?(
                 view,
                 "#{pool_id(pool)}-policy",
                 "Runs use the image set in this workspace's policy."
               )

        refute has_element?(view, "#{pool_id(pool)}-image")
        refute has_element?(view, "#{pool_id(pool)}-commit")
        refute has_element?(view, "#{pool_id(pool)}-default")
      end

      # A version for the target, which names no image, is the one in force for it.
      {:ok, _rule} = Policy.allow(scope, shop, %{host: "cdn.example"})
      view = open(conn, path)
      assert has_element?(view, "#{pool_id(mac)}-image")
      refute has_element?(view, "#{pool_id(mac)}-policy")
    end

    @tag needs: [:factory, :registry]
    test "the workspace's policy sets an image: a pool's failure, waiting and running lines stay",
         %{conn: conn, scope: scope, path: path} do
      mac = pool_fixture(scope, name: "mac-pool")
      linux = pool_fixture(scope, name: "linux-pool")
      arm = pool_fixture(scope, name: "arm-pool")
      shop = collection(scope)
      record!(scope, mac, shop, %{failure_cause: :timed_out, failed_at: DateTime.utc_now()})

      for pool <- [linux, arm] do
        {:ok, {:ok, _run}} =
          Repo.transact(fn -> {:ok, Dispatches.queue_prebuild(shop, pool, "env-1")} end)
      end

      _gateway = gateway_for!(scope, arm)
      %{access_key: key} = enrolled_key_fixture(scope, arm)
      {:ok, _claimed} = Dispatches.claim(key, Dispatches.now())
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})
      set_policy_image!(scope)
      view = open(conn, path)

      for pool <- [mac, linux, arm] do
        assert has_element?(
                 view,
                 "#{pool_id(pool)}-policy",
                 "Runs use the image set in this workspace's policy."
               )
      end

      assert has_element?(
               view,
               "#{pool_id(mac)}-failure",
               "The last build failed: it ran past 1 hour and 15 minutes."
             )

      assert has_element?(view, "#{pool_id(linux)}-waiting", "A build is waiting.")
      refute has_element?(view, "#{pool_id(linux)}-running")
      assert has_element?(view, "#{pool_id(arm)}-running", "A build is running.")
      refute has_element?(view, "#{pool_id(arm)}-waiting")
    end

    test "no card where the reader is not shown the feature", %{
      conn: conn,
      scope: scope,
      path: path
    } do
      pool_fixture(scope)
      collection(scope)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])

      view = open(conn, path)
      assert has_element?(view, "#target-overview")
      refute has_element?(view, "#target-environment")
    end
  end

  describe "Rebuild" do
    test "an owner's: a build queued for each pool, with its toast; again, already waiting",
         %{conn: conn, scope: scope, path: path} do
      mac = pool_fixture(scope, name: "mac-pool")
      linux = pool_fixture(scope, name: "linux-pool")
      collection(scope)
      view = open(conn, path)

      assert has_element?(
               view,
               "#target-environment-h + span + #target-environment-rebuild",
               "Rebuild"
             )

      assert has_element?(view, "#target-environment-rebuild .btn-busy", "Asking")

      view |> element("#target-environment-rebuild") |> render_click()
      assert has_element?(view, "#flash-info", "A build of acme/shop is queued.")
      assert has_element?(view, "#{pool_id(mac)}-waiting", "A build is waiting.")
      assert has_element?(view, "#{pool_id(linux)}-waiting", "A build is waiting.")

      view |> element("#target-environment-rebuild") |> render_click()
      assert has_element?(view, "#flash-info", "A build of acme/shop is already waiting.")
    end

    test "a member's, as every member may", %{scope: scope, path: path} do
      pool = pool_fixture(scope)
      collection(scope)
      %{user: member} = member_fixture(scope, :member)
      view = open(log_in_user(build_conn(), member), path)

      view |> element("#target-environment-rebuild") |> render_click()
      assert has_element?(view, "#flash-info", "A build of acme/shop is queued.")
      assert has_element?(view, "#{pool_id(pool)}-waiting")
    end

    test "a member who may not ask for a build sees no button; sent anyway, nothing is queued",
         %{scope: scope, path: path} do
      pool = pool_fixture(scope)
      shop = collection(scope)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoRebuild)
      %{user: member} = member_fixture(scope, :member)
      view = open(log_in_user(build_conn(), member), path)

      assert has_element?(view, "#target-environment")
      refute has_element?(view, "#target-environment-rebuild")

      render_click(view, "rebuild_environment", %{})
      refute has_element?(view, "#flash-info")
      refute has_element?(view, "#{pool_id(pool)}-waiting")
      assert Environments.fetch(pool.id, shop.id) == nil
    end

    test "no button where the target's collection is not assigned to the workspace",
         %{conn: conn, scope: scope, path: path} do
      pool_fixture(scope)
      other = workspace_fixture(scope.organisation)
      collection(scope, workspace_id: other.id)
      view = open(conn, path)

      assert has_element?(view, "#target-environment-none")
      refute has_element?(view, "#target-environment-rebuild")
    end

    test "Activity says it, about the target, and offers it in its filter",
         %{conn: conn, scope: scope, path: path} do
      pool_fixture(scope)
      collection(scope)
      view = open(conn, path)
      view |> element("#target-environment-rebuild") |> render_click()

      {:ok, activity, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
      render_async(activity)
      html = render(activity)

      assert html =~ "Asked for a build of its environment"
      assert html =~ "acme/shop"
      assert html =~ "Builds asked for"

      assert [%{"count" => 1}] =
               Repo.all(
                 from e in Apiary.Audit.Entry,
                   where: e.action == "target.rebuild_environment",
                   select: e.details
               )
    end
  end
end
