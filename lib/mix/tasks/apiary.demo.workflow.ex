defmodule Mix.Tasks.Apiary.Demo.Workflow do
  @shortdoc "Fills an empty database with a preview of the workflow model (dev and test only)"

  @moduledoc """
  Fills an empty database with a workspace to walk the workflow model in a browser: the
  Stages canvas with versions and a trial, and work items in five stage states:
  `running`, `at_gate`, `waiting_inputs`, `waiting_workflow` and `escalated`. All of it
  synthetic and neutral. A development tool: it stops in production.

      unset DATABASE_URL
      export APIARY_DEV_DATABASE=apiary_preview_workflow
      export QORY_FEATURES=observability,security,secrets,factory,workflow_model
      mix ecto.create && mix ecto.migrate && mix apiary.demo.workflow

  It needs the features `workflow_model` and `factory`, and stops with one line when
  either is off. It fills only the database `apiary_preview_workflow` or a database whose
  name starts with `apiary_walk_`, set in `APIARY_DEV_DATABASE` (`config/dev.exs` reads
  it), with `DATABASE_URL` unset. In the test environment it runs only under the tests.

  ## What it makes

  On an empty instance, through the contexts, as the pages and requests would:

    * **dana@example.com** sets up the instance, so she owns the organisation **Acme**
      and is its instance admin, with the software workspace **Web shop**.
      **ana@example.com** joins as an admin, **max@example.com** as a member.
    * Version 1 of the process comes from the workspace's creation; Dana saves versions 2
      and 3 (`Apiary.Processes.save/4`): version 2 adds an optional acceptance-criteria output to Shape, makes it a required
      input of Build, and adds to Build a loop of the workflows `capture-demo` and
      `fix-demo-findings`, which the harness does not declare; version 3 removes that
      loop again, and adds an optional mockup output to Shape and an optional screenshot
      output to Verify.
    * A read of Web shop's harness is recorded, which lists only `explore-a-ticket`.
    * The adapter **Tracker** is made and connected for Acme, with the repository
      `acme/web-shop` in Web shop and its tickets; Dana and Max take ten of them in.
      With `workflow_model` on, a take in enters Explore.
    * The node pool **preview-pool** and its key. A run of Explore needs a gateway to be
      claimed, and the preview has none: the task hands a waiting run over in the
      database and posts its events under the pool's key (`Apiary.Runs.Ingest`), a
      result and an exit, as a gateway would. The exit ends the run as any exit does.
    * The work items, by their ticket:
      * Save a basket for later: Explore running, its first run waiting for a machine,
        on the trial version;
      * Checkout total ignores the voucher after a reload: Explore at its gate, with a
        proposal;
      * Search returns no results for words with umlauts: Explore approved by Dana,
        Shape at its gate;
      * Basket badge shows 0 after signing in: Explore and Shape approved by Dana, Build
        waiting for its acceptance-criteria input;
      * Product images load twice on the listing page: three rounds of questions; Dana
        answers the first two, and the third escalates at the round limit;
      * TypeError in the address form after autofill: a result that fails the explore
        schema, escalated as a run that stopped;
      * Show delivery dates on the product page: Shape at its gate, with an
        acceptance-criteria document (Markdown with a Mermaid diagram) and a mockup
        image that Max added;
      * Remove the old promotion banner: acceptance criteria that Max added in Shape,
        then Shape approved by Dana, Build at its gate;
      * Record a demo of the new checkout: on version 2, acceptance criteria that Max
        added in Shape, then Shape approved by Dana, Build waiting for its workflows,
        which the harness does not declare;
      * Show the size guide in German: Explore escalated, as a run that stopped. The
        harness file at the root of `acme/web-shop` has no skill `explore-a-ticket`, so
        qory closed the run failed with the reason `workflow_not_in_harness`, which the
        run's page and the work item show with the workflow and that file.
    * Last, Dana saves a trial version (Explore with 2 rounds instead of 3) and assigns
      the first work item to it.

  Running it again on the instance it filled adds nothing. The trial version, the fill's
  last step, marks a fill that finished; an Acme without it is a fill that stopped half
  way, and the task stops with an error. To fill again from nothing, drop the database
  and create it again.

  ## Signing in

  Open `/users/log-in` on the server, choose to log in with a password, and enter one of
  these addresses with its password:

    * `dana@example.com` with `demo-workflow-dana`, the owner;
    * `ana@example.com` with `demo-workflow-ana`, an admin;
    * `max@example.com` with `demo-workflow-max`, a member.
  """

  use Mix.Task

  import Ecto.Query

  alias Apiary.{AccessKeys, Accounts, Adapters, Artifacts, Nodes, Organisations}
  alias Apiary.{Processes, Repo, Sources, Stages, WorkItems}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Adapters.{Collections, Connections, Grants}
  alias Apiary.Adapters.Wire, as: AdapterWire
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.{Batch, Ingest, Run}
  alias Apiary.Sources.Backlog
  alias Apiary.Sources.Wire, as: SourceWire
  alias Apiary.WorkItems.{Explore, WorkItem}
  alias Mix.Tasks.Apiary.Demo.Shell

  @owner {"dana@example.com", "demo-workflow-dana"}
  @people [
    {"ana@example.com", "demo-workflow-ana", :admin},
    {"max@example.com", "demo-workflow-max", :member}
  ]
  @organisation "Acme"
  @workspace "Web shop"
  @database_prefix "apiary_walk_"
  @preview_database "apiary_preview_workflow"

  @host "https://tracker.example.com"
  @code_host "git.example.com"
  @repository "acme/web-shop"
  @grant_ref "G_acme"
  @pool "preview-pool"
  @forager "0.10.0"

  # The work items, in the order they are taken in: what happens to each, who takes its
  # ticket in, and its ticket: number, title and the line its body opens with.
  @work_items [
    {:explore_running, :max, 101, "Save a basket for later",
     "Customers ask to park a basket without checking out."},
    {:explore_gate, :dana, 102, "Checkout total ignores the voucher after a reload",
     "Reloading the payment step drops the voucher from the total."},
    {:shape_gate, :max, 103, "Search returns no results for words with umlauts",
     "Searching for Kühlschrank finds nothing."},
    {:build_inputs, :dana, 104, "Basket badge shows 0 after signing in",
     "The badge counts the guest basket, not the merged one."},
    {:round_limit, :max, 105, "Product images load twice on the listing page",
     "The listing fetches each image once for the thumbnail and once for the zoom."},
    {:run_stopped, :dana, 106, "TypeError in the address form after autofill",
     "Reported 37 times in the last day."},
    {:artifacts, :max, 107, "Show delivery dates on the product page",
     "The warehouse API has a date for each postcode; the page shows none."},
    {:approved, :dana, 108, "Remove the old promotion banner",
     "The autumn promotion ended; the banner code is still shipped."},
    {:waiting_workflow, :dana, 109, "Record a demo of the new checkout",
     "Sales asks for a short video of the three checkout steps."},
    {:workflow_missing, :max, 110, "Show the size guide in German",
     "The size guide on the product page is in English only."}
  ]

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod,
      do: Mix.raise("mix apiary.demo.workflow is a development tool: not in prod")

    {_opts, _rest} = OptionParser.parse!(args, strict: [])

    # The database is checked before the app starts, so nothing reaches one it does not fill.
    Mix.Task.run("app.config")

    tests? = Process.whereis(ExUnit.Server) != nil

    if refusal = refusal(Mix.env(), tests?, Repo.config()[:database], System.get_env()),
      do: Mix.raise(refusal)

    # Set before the app starts: its boot logs the set-up link, with its one-time code, at
    # info. The query log of a fill is thousands of lines nobody reads.
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")

    for feature <- [:workflow_model, :factory], not Apiary.Features.on?(feature) do
      Mix.raise(
        "Add #{feature} to QORY_FEATURES and run the task again: " <>
          "the preview needs the feature #{feature}, and it is off."
      )
    end

    Mix.shell().info("Database #{Repo.config()[:database]}")

    case instance() do
      :empty ->
        inline_projection(&fill/0)

      :filled ->
        Mix.shell().info("The preview is there already: nothing more is made.")

      :unfinished ->
        Mix.raise("""
        The preview's fill did not finish. Fill it again from nothing:

            unset DATABASE_URL
            export APIARY_DEV_DATABASE=#{Repo.config()[:database]}
            mix ecto.drop && mix ecto.create && mix ecto.migrate && mix apiary.demo.workflow
        """)

      :other ->
        Mix.raise(
          "Fill an empty database: this instance has an organisation that is not the preview's."
        )
    end

    sign_in_lines()
  end

  @doc false
  # Why the task must not fill `database`, the one the app is configured with in the Mix
  # environment `mix_env`, given whether the tests run (`tests?`) and the shell's
  # variables `env`; nil when it may. The tests fill their partitioned database, and the
  # test environment is refused outside them. Anywhere else only the database that
  # APIARY_DEV_DATABASE names is filled, `apiary_preview_workflow` or a name that starts
  # with `apiary_walk_`, with no DATABASE_URL to replace it. An empty DATABASE_URL replaces nothing, so it counts as
  # unset.
  @spec refusal(atom, boolean, String.t() | nil, %{optional(String.t()) => String.t()}) ::
          String.t() | nil
  def refusal(:test, true, _database, _env), do: nil

  def refusal(:test, false, database, _env),
    do: refused("the test environment's database, #{database}, belongs to the tests")

  def refusal(_mix_env, _tests?, database, env) do
    named = env["APIARY_DEV_DATABASE"]

    cond do
      env["DATABASE_URL"] not in [nil, ""] ->
        refused("DATABASE_URL is set, and it replaces the database in APIARY_DEV_DATABASE")

      named in [nil, ""] ->
        refused("APIARY_DEV_DATABASE is not set")

      named != @preview_database and not String.starts_with?(named, @database_prefix) ->
        refused(
          "#{named} is not #{@preview_database} and does not start with #{@database_prefix}"
        )

      database != named ->
        refused(
          "the app is configured with the database #{inspect(database)}, " <>
            "not #{named}, the value of APIARY_DEV_DATABASE"
        )

      true ->
        nil
    end
  end

  defp refused(reason) do
    """
    mix apiary.demo.workflow fills only a preview database: #{reason}.
    Run it in development, with DATABASE_URL unset and APIARY_DEV_DATABASE set to
    #{@preview_database} or to a database whose name starts with #{@database_prefix}:

        unset DATABASE_URL
        export APIARY_DEV_DATABASE=#{@preview_database}
        mix ecto.create && mix ecto.migrate && mix apiary.demo.workflow
    """
  end

  # Whether the instance has no organisation in use, is the preview's, is a fill of it
  # that did not finish, or is anybody else's. The preview's has one organisation in use,
  # Acme, with Dana and the workspace Web shop, whose trial version is the fill's last
  # step.
  defp instance do
    in_use = Repo.all(from o in Organisation, where: is_nil(o.deletion_marked_at))

    with [%Organisation{name: @organisation} = acme] <- in_use,
         %User{} <- Accounts.get_user_by_email(elem(@owner, 0)) do
      workspace =
        Repo.one(
          from w in Workspace,
            where: w.organisation_id == ^acme.id and w.name == @workspace,
            where: is_nil(w.deletion_marked_at)
        )

      # A fill that stopped between the set-up and the workspace has Acme without Web shop.
      if workspace && trial(workspace), do: :filled, else: :unfinished
    else
      [] -> :empty
      _other -> :other
    end
  end

  defp trial(workspace),
    do: Enum.find(Processes.list_versions(workspace), &(&1.status == :trial))

  # A run's events are projected in the process that posts them while the fill runs, so
  # each run has ended, and its stage has moved, before the next step reads it.
  defp inline_projection(fun) do
    previous = Application.get_env(:apiary, Apiary.Runs.Projector)

    Application.put_env(
      :apiary,
      Apiary.Runs.Projector,
      Keyword.put(previous || [], :async, false)
    )

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:apiary, Apiary.Runs.Projector, previous),
        else: Application.delete_env(:apiary, Apiary.Runs.Projector)
    end
  end

  ## The fill

  defp fill do
    dana = sign_up!()
    dana_scope = scope!(dana)

    people =
      for {email, password, level} <- @people, into: %{} do
        {level, dana_scope |> join!(email, password, level) |> scope!()}
      end

    versions!(dana_scope)

    # A stage waits for a workflow only against a recorded read of the harness: with none,
    # its run starts.
    :ok = Processes.record_declared(dana_scope.workspace, Processes.qory_workflows())

    Shell.info(
      "Process versions 1 to 3: version 1 from the workspace's creation, 2 and 3 saved by Dana"
    )

    tracker!(dana_scope)
    key = pool!(dana_scope)

    ctx = %{
      dana: dana_scope,
      ana: people.admin,
      max: people.member,
      key: key,
      stages: stage_ids(Processes.current(dana_scope.workspace).document)
    }

    made =
      for {what, taker, number, title, _line} <- @work_items do
        work_item = take_in!(Map.fetch!(ctx, taker), title)
        {what, number, drive!(what, ctx, work_item)}
      end

    {:explore_running, _number, running} = List.keyfind(made, :explore_running, 0)
    trial = trial!(dana_scope, running)

    summary(ctx, made, trial)
  end

  # The instance's set-up, as its set-up link makes it, and Web shop, a software
  # workspace, as an owner creates the first one; then a log-in link followed, which
  # confirms the address, and a password set, as Settings would.
  defp sign_up! do
    {email, password} = @owner

    {:ok, %{user: user}} =
      Apiary.Setup.set_up(
        Apiary.Setup.code!(),
        %{"email" => email, "organisation_name" => @organisation},
        password: :optional,
        origin: %{worker: "demo"}
      )

    {:ok, _workspace} =
      user
      |> Scope.for_user()
      |> Organisations.load_scope()
      |> Scope.put_origin(%{worker: "demo"})
      |> Organisations.create_first_workspace(%{"domain" => "software", "name" => @workspace})

    with_password!(user, password)
  end

  # An account made as a sign-up makes one, invited by Dana, and its invitation accepted,
  # then given `level`.
  defp join!(dana, email, password, level) do
    {:ok, user} = Accounts.register_user(%{email: email})
    user = with_password!(user, password)

    token =
      capture(fn url_fun ->
        case Organisations.invite_member(dana, %{"email" => email}, url_fun) do
          {:ok, invitation} -> {:ok, invitation}
          {:ok, invitation, {:link, _url}} -> {:ok, invitation}
          {:error, reason} -> Shell.raise!("#{email} was not invited: #{inspect(reason)}")
        end
      end)

    {:ok, membership} = Organisations.accept_invitation(user, token)

    if level != :member,
      do: {:ok, _changed} = Organisations.set_member_level(dana, membership.id, level)

    user
  end

  defp with_password!(user, password) do
    token = capture(&Accounts.deliver_login_instructions(user, &1))
    {:ok, {user, _expired}} = Accounts.login_user_by_magic_link(token)

    {:ok, {user, _expired}} =
      Accounts.update_user_password(user, %{
        password: password,
        password_confirmation: password
      })

    user
  end

  # The person's scope of Web shop, as their page has it.
  defp scope!(%User{} = user) do
    workspace =
      Repo.one!(
        from w in Workspace,
          join: o in assoc(w, :organisation),
          where: o.slug == "acme" and w.name == @workspace and is_nil(w.deletion_marked_at)
      )

    case Organisations.resolve_scope(Scope.for_user(user), "acme", workspace.slug) do
      {:ok, scope} -> Scope.put_origin(scope, %{worker: "demo"})
      :error -> Shell.raise!("#{user.email} does not reach acme/#{workspace.slug}")
    end
  end

  # The token a mail would have carried, handed to the URL function instead of sent.
  defp capture(fun) do
    ref = make_ref()
    parent = self()

    fun.(fn token ->
      send(parent, {ref, token})
      "#{Apiary.Setup.public_url()}/demo/#{token}"
    end)

    receive do
      {^ref, token} -> token
    after
      0 -> Shell.raise!("no token was handed over")
    end
  end

  ## The process

  # Versions 1 to 3: the workspace's creation makes version 1 (author nil), and Dana
  # saves the rest.
  defp versions!(%Scope{workspace: workspace} = scope) do
    have = length(Processes.list_versions(workspace))

    for document <- Enum.drop(documents(workspace), have) do
      ok!(Processes.save(scope, workspace, document, trial: false), "a process version")
    end
  end

  @doc false
  # documents/1 is the process of versions 1, 2 and 3 of `workspace`, from its type's
  # default; trial_document/1 is the trial's, from version 3.
  def documents(%Workspace{} = workspace) do
    v1 = Processes.default_document(workspace)

    v2 =
      v1
      |> update_stage("Shape", &Map.put(&1, "outputs", [optional("acceptance-criteria")]))
      |> update_stage("Build", fn stage ->
        stage
        |> Map.put("inputs", [%{"type" => "acceptance-criteria", "required" => true}])
        |> Map.put("sequence", [
          %{
            "loop" => %{
              "rounds" => 3,
              "body" => [%{"workflow" => "capture-demo"}, %{"workflow" => "fix-demo-findings"}]
            }
          }
        ])
      end)

    v3 =
      v2
      |> update_stage("Build", &Map.put(&1, "sequence", []))
      |> update_stage(
        "Shape",
        &Map.update!(&1, "outputs", fn outputs -> outputs ++ [optional("mockup")] end)
      )
      |> update_stage("Verify", &Map.put(&1, "outputs", [optional("screenshot")]))

    [v1, v2, v3]
  end

  @doc false
  def trial_document(%Workspace{} = workspace) do
    workspace
    |> documents()
    |> List.last()
    |> update_stage("Explore", fn stage ->
      Map.update!(stage, "sequence", fn sequence ->
        Enum.map(sequence, fn
          %{"loop" => loop} = entry -> %{entry | "loop" => Map.put(loop, "rounds", 2)}
          entry -> entry
        end)
      end)
    end)
  end

  defp optional(type), do: %{"type" => type, "required" => false}

  defp update_stage(document, name, fun) do
    Map.update!(document, "stages", fn stages ->
      Enum.map(stages, fn
        %{"name" => ^name} = stage -> fun.(stage)
        stage -> stage
      end)
    end)
  end

  defp stage_ids(document),
    do: Map.new(document["stages"], &{&1["name"], &1["id"]})

  defp trial!(%Scope{workspace: workspace} = scope, %WorkItem{} = work_item) do
    trial =
      ok!(
        Processes.save(scope, workspace, trial_document(workspace), trial: true),
        "the trial version"
      )

    ok!(Processes.assign(scope, current(scope, work_item), trial), "the trial's work item")
    trial
  end

  ## The adapter, its repository and its tickets

  # Dana, an instance admin who signed in a minute ago, makes the adapter Tracker, which
  # enrols its key and declares itself; she connects Acme, the adapter lists
  # `acme/web-shop`, she assigns it to Web shop, and the adapter posts its tickets.
  defp tracker!(%Scope{} = dana) do
    admin = %{dana | user: %{dana.user | authenticated_at: DateTime.utc_now(:second)}}
    {:ok, adapter} = Adapters.create_adapter(admin, %{"name" => "Tracker"})
    {:ok, _row, code} = Adapters.create_code(admin, adapter)
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, key} = AccessKeys.enrol(enrolment(code, public, secret, "tracker"))

    {:ok, declaration} = AdapterWire.declaration(Jason.encode!(declaration()))
    {:ok, adapter} = Adapters.declare(key_scope(key), declaration)

    connection = connect!(dana, adapter, key, secret)
    list_collection!(key, connection)

    ids =
      for %{name: @repository, id: id} <- Collections.list_collections(dana, connection),
          do: id

    {:ok, _changed} = Collections.assign_collections(dana, connection, ids, dana.workspace)
    tickets!(key)
    Shell.info("Tracker connected, with #{@repository} and #{length(@work_items)} tickets")
  end

  defp enrolment(code, public, secret, name) do
    code = Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())
    public = Ed25519.encode(public)
    now = System.os_time(:second)
    message = SignedMessage.enrolment(code, public, name, now)
    proof = :crypto.sign(:eddsa, :none, message, [secret, :ed25519])

    {:ok, request} =
      Enrolment.decode(
        Jason.encode!(%{
          "version" => 1,
          "code" => code,
          "name" => name,
          "public_key" => public,
          "timestamp" => now,
          "proof" => Ed25519.encode(proof)
        })
      )

    request
  end

  defp declaration do
    %{
      "version" => 1,
      "time" => time(DateTime.utc_now()),
      "connect_url" => "https://tracker.example.com/connect",
      "sync" => %{"default_interval" => 900, "minimum_interval" => 300, "sends_changes" => true},
      "description" => %{
        "version" => 1,
        "name" => "tracker",
        "title" => "Tracker",
        "program_version" => "0.4.0",
        "settings" => %{"type" => "object"},
        "roles" => %{
          "source" => %{
            "description" => "Reads the open tickets of Tracker repositories.",
            "program" => "tracker-adapter",
            "setup" => %{
              "command" => "tracker-adapter setup",
              "help" => "Registers the adapter with the address of the Tracker site."
            },
            "start" => "tracker-adapter serve --secret-file /etc/tracker-adapter/secret",
            "connect" => "Sign in to Tracker and choose the repositories it reads.",
            "access" =>
              "In Tracker, open Settings, then Adapters, to change which repositories it reads.",
            "disconnect" => "In Tracker, open Settings, then Adapters, and remove the adapter.",
            "item_noun" => %{"one" => "ticket", "other" => "tickets"},
            "collection_noun" => %{"one" => "repository", "other" => "repositories"}
          }
        }
      }
    }
  end

  # The scope of the adapter's key, read as `AccessKeys.fetch_for_verification/1` returns
  # it for a verified request, after a use of the key is recorded, as for each of the
  # adapter's requests.
  defp key_scope(key) do
    :ok = AccessKeys.touch_delivery(key, %{})
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  # Dana presses Install and comes back with the adapter's linked return; the adapter then
  # reports the grant of Acme's external account under that pass.
  defp connect!(dana, adapter, key, secret) do
    {:ok, _url, {connection_id, nonce}} = Adapters.connect(dana, adapter)
    token = return_token(secret, connection_id, nonce)
    {:ok, :linked} = Connections.complete_return(dana, connection_id, token, nonce)

    body = %{
      "version" => 1,
      "time" => time(DateTime.utc_now()),
      "connection_id" => connection_id,
      "grant_ref" => @grant_ref,
      "account" => %{"ref" => "1001", "title" => "acme"},
      "pass_nonce" => nonce
    }

    {:ok, decoded} = body |> Jason.encode!() |> AdapterWire.decode()
    {:ok, report} = AdapterWire.grant_report(decoded)
    {:ok, _grant} = Grants.report(key_scope(key), report)
    Map.fetch!(Connections.live_by_adapter(dana), adapter.id)
  end

  defp return_token(secret, connection_id, nonce) do
    payload =
      Jason.encode!(%{
        "version" => 1,
        "connection_id" => connection_id,
        "nonce" => nonce,
        "outcome" => "linked",
        "expires_at" => time(DateTime.add(DateTime.utc_now(), 240, :second))
      })

    signature =
      :crypto.sign(:eddsa, :none, SignedMessage.connect_return(payload), [secret, :ed25519])

    Ed25519.encode(payload) <> "." <> Ed25519.encode(signature)
  end

  defp list_collection!(key, connection) do
    now = DateTime.utc_now()

    body = %{
      "version" => 1,
      "time" => time(now),
      "connection_id" => connection.public_id,
      "collections" => [
        %{
          "ref" => @repository,
          "url" => "#{@host}/#{@repository}",
          "title" => @repository,
          "grant_ref" => @grant_ref,
          "target" => %{"system" => @code_host, "path" => @repository}
        }
      ],
      "listing" => %{
        "id" => "collections-#{System.os_time(:second)}",
        "part" => 1,
        "started_at" => time(DateTime.add(now, -5, :second)),
        "complete" => true
      }
    }

    {:ok, decoded} = body |> Jason.encode!() |> AdapterWire.decode()
    {:ok, listing} = AdapterWire.listing(decoded)
    {:ok, :accepted} = Collections.post_listing(key_scope(key), listing)
  end

  defp tickets!(key) do
    now = DateTime.utc_now()

    body = %{
      "version" => 1,
      "time" => time(now),
      "collection_ref" => @repository,
      "items" =>
        for {_what, _taker, number, title, line} <- @work_items do
          filed = DateTime.add(now, -number * 3600, :second)

          %{
            "ref" => "#{@repository}##{number}",
            "key" => "##{number}",
            "type" => "task",
            "url" => "#{@host}/#{@repository}/tickets/#{number}",
            "title" => title,
            "body" => "#{line}\n\n## Expected\n\nThe same result as in production.\n",
            "body_format" => "markdown",
            "filed_by" => %{"name" => "Dana", "kind" => "person"},
            "labels" => ["web-shop"],
            "state" => "open",
            "state_reason" => nil,
            "comment_count" => 0,
            "created_at" => time(filed),
            "updated_at" => time(filed)
          }
        end,
      "listing" => %{
        "id" => "tickets-#{System.os_time(:second)}",
        "part" => 1,
        "started_at" => time(DateTime.add(now, -5, :second)),
        "complete" => true
      }
    }

    {:ok, items} = SourceWire.items(Jason.encode!(body))
    {:ok, :accepted} = Sources.post_items(key_scope(key), items)
  end

  ## The node pool

  # The pool the preview's runs are bound to, with a key added by its public key, as
  # Generate a key adds one made in a browser; the private half is dropped. Returns the
  # key as `AccessKeys.fetch_for_verification/1` returns it, with its workspace and node.
  defp pool!(%Scope{} = dana) do
    {:ok, pool} =
      Nodes.create_node(dana, %{"kind" => "pool", "name" => @pool, "instance_limit" => 4})

    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, key} =
      AccessKeys.add_access_key(dana, pool, %{
        "public_key" => Base.url_encode64(public, padding: false),
        "label" => @pool,
        "allow_secrets" => false
      })

    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    verified
  end

  ## The work items

  defp take_in!(%Scope{} = scope, title) do
    [%{id: ticket_id}] =
      Backlog.list_tickets(scope, %{view: :open, search: title}).rows
      |> Enum.filter(&(&1.title == title))

    ok!(WorkItems.take_in(scope, ticket_id, %{"first_instruction" => ""}), "a take in")
  end

  # Its first run waits for a machine.
  defp drive!(:explore_running, _ctx, work_item), do: work_item

  defp drive!(:explore_gate, ctx, work_item) do
    record_result!(ctx, work_item, {:result, proposal(work_item.title)})
    current(ctx.dana, work_item)
  end

  defp drive!(:shape_gate, ctx, work_item) do
    work_item = drive!(:explore_gate, ctx, work_item)
    confirm!(ctx.dana, work_item)
  end

  defp drive!(:build_inputs, ctx, work_item) do
    work_item = drive!(:shape_gate, ctx, work_item)
    approve!(ctx.dana, work_item, "Shaped enough to build.")
  end

  defp drive!(:round_limit, ctx, work_item), do: rounds!(ctx, work_item, 1)

  defp drive!(:run_stopped, ctx, work_item) do
    # A result the explore schema rejects: a verdict without the members it requires.
    record_result!(ctx, work_item, {:text, ~s({"version":1,"verdict":"understood"})})
    current(ctx.dana, work_item)
  end

  # The run's harness walk read the repository's root harness file, and qory found no
  # skill explore-a-ticket in the harness it composed from it: the run ends failed with
  # `workflow_not_in_harness` before its runtime starts, and Explore escalates.
  defp drive!(:workflow_missing, ctx, work_item) do
    record_result!(ctx, work_item, :workflow_not_in_harness)
    current(ctx.dana, work_item)
  end

  defp drive!(:artifacts, ctx, work_item) do
    work_item = drive!(:shape_gate, ctx, work_item)

    push!(ctx.max, work_item, "acceptance-criteria", ctx.stages["Shape"], [
      %{
        filename: "acceptance-criteria.md",
        content_type: "text/markdown",
        binary: delivery_dates_criteria()
      }
    ])

    push!(ctx.max, work_item, "mockup", ctx.stages["Shape"], [
      %{filename: "product-page.png", content_type: "image/png", binary: mockup_png()}
    ])

    current(ctx.dana, work_item)
  end

  defp drive!(:approved, ctx, work_item) do
    work_item = drive!(:shape_gate, ctx, work_item)

    push!(ctx.max, work_item, "acceptance-criteria", ctx.stages["Shape"], [
      %{
        filename: "acceptance-criteria.md",
        content_type: "text/markdown",
        binary: banner_criteria()
      }
    ])

    approve!(ctx.dana, work_item, "The criteria cover the banner and its styles.")
  end

  # On version 2, whose Build runs workflows the harness does not declare: Build does not
  # start, and waits for them.
  defp drive!(:waiting_workflow, ctx, work_item) do
    work_item = drive!(:shape_gate, ctx, work_item)

    version_2 =
      Enum.find(Processes.list_versions(ctx.dana.workspace), &(&1.number == 2)) ||
        Shell.raise!("Web shop has no process version 2")

    ok!(Processes.assign(ctx.dana, work_item, version_2), "the work item on version 2")

    push!(ctx.max, work_item, "acceptance-criteria", ctx.stages["Shape"], [
      %{
        filename: "acceptance-criteria.md",
        content_type: "text/markdown",
        binary: demo_criteria()
      }
    ])

    approve!(ctx.dana, work_item, "Ready for the demo recording.")
  end

  # Questions in each round, answered by Dana, until the stage escalates at its round
  # limit; at most one round more than the default process's three.
  defp rounds!(ctx, work_item, round) when round <= 4 do
    run = record_result!(ctx, work_item, {:result, questions(round)})
    work_item = current(ctx.dana, work_item)

    if escalated?(work_item) do
      work_item
    else
      ok!(WorkItems.answer(ctx.dana, work_item, run.attempt, answers(round)), "an answer")
      work_item = current(ctx.dana, work_item)
      if escalated?(work_item), do: work_item, else: rounds!(ctx, work_item, round + 1)
    end
  end

  defp rounds!(_ctx, work_item, _round),
    do: Shell.raise!("#{work_item.title} did not escalate at the round limit")

  defp escalated?(%WorkItem{stage_state: state}), do: state == :escalated

  # Explore's gate is approved by confirming the run's proposal, as the work item page
  # does it.
  defp confirm!(%Scope{} = scope, %WorkItem{} = work_item) do
    %{status: :confirm, step: %{attempt: attempt}} =
      Explore.current(work_item, DateTime.utc_now())

    ok!(WorkItems.confirm(scope, current(scope, work_item), attempt), "a confirmation")
    current(scope, work_item)
  end

  defp approve!(%Scope{} = scope, %WorkItem{} = work_item, note) do
    work_item = current(scope, work_item)

    ok!(
      Stages.approve(scope, work_item, note, expect_stage: work_item.stage_id),
      "an approval"
    )

    current(scope, work_item)
  end

  defp push!(%Scope{} = scope, %WorkItem{} = work_item, type, stage_id, files) do
    ok!(
      Artifacts.push({:person, scope}, current(scope, work_item), type, files,
        name: "main",
        stage_id: stage_id,
        note: "Added for the review of Shape."
      ),
      "an artifact"
    )
  end

  defp current(%Scope{} = scope, %WorkItem{public_id: id}),
    do: WorkItems.get_by_public_id(scope, id)

  defp ok!({:ok, value}, _what), do: value
  defp ok!(other, what), do: Shell.raise!("#{what} was not made: #{inspect(other)}")

  ## A run of Explore and its result

  # The waiting run of `work_item`'s Explore, handed over to the preview's pool, and its
  # events posted under the pool's key as a gateway posts them: it starts, returns
  # `result` and exits. The exit, once projected, ends the run of the queue, which
  # settles the result. Returns the run of the queue.
  defp record_result!(%{key: key}, %WorkItem{} = work_item, result) do
    dispatch_run =
      Repo.one(
        from d in DispatchRun,
          where: d.work_item_id == ^work_item.id and d.state == :waiting,
          order_by: [desc: d.attempt],
          limit: 1
      ) || Shell.raise!("#{work_item.title} has no run of Explore waiting")

    now = DateTime.utc_now()
    if result == :workflow_not_in_harness, do: walked_file!(dispatch_run)
    run = hand_over!(dispatch_run, work_item, key, now)

    meta = %{
      contract_version: 1,
      delivery_id: Ecto.UUID.generate(),
      forager_version: @forager,
      run_configuration: nil
    }

    case Ingest.ingest(key, batch!(run, work_item, result, now), meta) do
      {:ok, %{status: 202}} -> dispatch_run
      other -> Shell.raise!("the run of #{work_item.title} was not stored: #{inspect(other)}")
    end
  end

  # Stands in for the claim and handover, which need a gateway the preview does not have:
  # writes the handed-over run of the queue and its registered run straight to the
  # database. For development only, as is the whole task.
  defp hand_over!(%DispatchRun{} = dispatch_run, %WorkItem{} = work_item, key, now) do
    {:ok, run} =
      Repo.transact(fn ->
        {1, _rows} =
          Repo.update_all(
            from(d in DispatchRun, where: d.id == ^dispatch_run.id and d.state == :waiting),
            set: [state: :handed_over]
          )

        run =
          Repo.insert!(%Run{
            public_id: Run.new_public_id(),
            organisation_id: dispatch_run.organisation_id,
            workspace_id: dispatch_run.workspace_id,
            node_run_id: dispatch_run.run_id,
            node_id: key.node_id,
            access_key_id: key.id,
            state: "pending",
            registered_at: now,
            # A direct registration has every registration column set.
            registration_labels: %{},
            registration_about: %{"kind" => "Explore", "title" => work_item.title},
            registration_digest: :crypto.hash(:sha256, dispatch_run.run_id),
            registration_interval_seconds: 60,
            registration_answer_digest:
              "sha256=" <> Base.encode16(:crypto.hash(:sha256, "{}"), case: :lower),
            projected_sequence: Run.projected_from(%{registered_at: now}),
            dispatch_run_id: dispatch_run.id,
            inserted_at: now,
            updated_at: now
          })

        {:ok, run}
      end)

    run
  end

  # The run's harness walk as the walk's job leaves it for a target with a root harness
  # file: resolved, from that file. The preview runs no walk job.
  defp walked_file!(%DispatchRun{id: id}) do
    {1, _rows} =
      Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^id),
        set: [state: :resolved, origin: :file, workflow: "explore-a-ticket"]
      )
  end

  defp batch!(%Run{node_run_id: subject}, work_item, result, now) do
    body =
      result
      |> events(work_item)
      |> Enum.with_index(2)
      |> Enum.map(fn {{seconds, {type, data}}, sequence} ->
        %{
          "specversion" => "1.0",
          "id" => Ecto.UUID.generate(),
          "source" => "urn:qory:run:" <> subject,
          "type" => type,
          "subject" => subject,
          "time" =>
            now
            |> DateTime.add(seconds, :second)
            |> DateTime.truncate(:millisecond)
            |> DateTime.to_iso8601(),
          "sequence" => sequence |> Integer.to_string() |> String.pad_leading(10, "0"),
          "data" => data
        }
      end)

    case Batch.parse(Jason.encode!(body)) do
      {:ok, batch} -> batch
      :error -> Shell.raise!("the events of #{work_item.title} are not a batch")
    end
  end

  # A run that qory closed before the runtime started: the run starts, then exits failed
  # with the reason, and no session.
  defp events(:workflow_not_in_harness, work_item),
    do: [
      {-3, {"dev.qory.run.started", started(work_item)}},
      {0,
       {"dev.qory.run.exited",
        %{"state" => "failed", "reason" => "workflow_not_in_harness", "exit_code" => -1}}}
    ]

  defp events(result, work_item) do
    text =
      case result do
        {:result, document} -> Jason.encode!(document)
        {:text, text} -> text
      end

    [
      {-90, {"dev.qory.run.started", started(work_item)}},
      {-89,
       {"dev.qory.session.started",
        %{
          "session" => 1,
          "runtime" => "claude",
          "command" => "claude",
          "args" => [],
          "dir" => "/work",
          "interactive" => false
        }}},
      {-2,
       {"dev.qory.runtime.result",
        %{
          "session_id" => Ecto.UUID.generate(),
          "outcome" => "success",
          "is_error" => false,
          "turns" => 6,
          "duration_ms" => 86_000,
          "result" => text
        }}},
      {-1,
       {"dev.qory.session.exited",
        %{"session" => 1, "state" => "completed", "exit_code" => 0, "duration_ms" => 88_000}}},
      {0,
       {"dev.qory.run.exited",
        %{"state" => "completed", "exit_code" => 0, "duration_ms" => 90_000}}}
    ]
  end

  defp started(work_item),
    do: %{
      "opened_by" => "run",
      "forager_version" => @forager,
      "host" => @pool,
      "wall" => "docker",
      "labels" => %{},
      "about" => %{"kind" => "Explore", "title" => work_item.title}
    }

  # An explore v1 result whose verdict is `understood`.
  defp proposal(title) do
    %{
      "version" => 1,
      "verdict" => "understood",
      "complexity" => %{"level" => "standard", "reason" => "One page and its tests change."},
      "understanding" => "The ticket is about this change: #{title}.",
      "scope" => %{
        "in" => ["Reproduce it on the staging build", "Change the page and add a test"],
        "out" => ["Other pages of the web shop"]
      },
      "approach" => %{
        "summary" => "Find the cause in the web shop's code, change it and add a test for it.",
        "alternatives" => [
          %{
            "summary" => "Hide the symptom on the page.",
            "reason" => "The cause would stay."
          }
        ]
      },
      "knowledge" => [
        %{
          "text" => "The web shop's tests run on every change.",
          "sources" => ["https://docs.example.com/web-shop"]
        }
      ]
    }
  end

  # An explore v1 result whose verdict is `not_understood`.
  defp questions(round) do
    %{
      "version" => 1,
      "verdict" => "not_understood",
      "questions" => [
        "Round #{round}: which listing page loads the images twice?",
        "Round #{round}: on which devices does it happen?"
      ]
    }
  end

  defp answers(round) do
    %{
      "1" => "The category listing, round #{round}.",
      "2" => "Phones and desktops alike."
    }
  end

  ## The artifacts that Max adds

  defp delivery_dates_criteria do
    """
    # Delivery dates on the product page

    ## Acceptance criteria

    1. The product page shows a delivery date for the postcode the customer entered.
    2. Without a postcode, the page shows the earliest date for the customer's country.
    3. When the warehouse has no date, the page shows "Delivery date on request".

    ## Flow

    ```mermaid
    flowchart LR
      A[Product page] --> B{Postcode known?}
      B -- yes --> C[Read the date from the warehouse]
      B -- no --> D[Earliest date for the country]
      C --> E[Show the date]
      D --> E
    ```
    """
  end

  defp demo_criteria do
    """
    # Record a demo of the new checkout

    ## Acceptance criteria

    1. The video shows the address, delivery and payment steps in that order.
    2. The video is at most two minutes long.
    """
  end

  defp banner_criteria do
    """
    # Remove the old promotion banner

    ## Acceptance criteria

    1. No page of the web shop shows the autumn promotion banner.
    2. The banner's styles and images are no longer shipped.
    """
  end

  # A mockup of the product page, 240 by 160 pixels, as a PNG made here: a header, a
  # product image, two lines of text and a button.
  @doc false
  def mockup_png do
    {width, height} = {240, 160}

    rows =
      for y <- 0..(height - 1), into: <<>> do
        row = for x <- 0..(width - 1), into: <<>>, do: pixel(x, y)
        <<0>> <> row
      end

    header = <<width::32, height::32, 8, 2, 0, 0, 0>>

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", header) <> chunk("IDAT", :zlib.compress(rows)) <> chunk("IEND", <<>>)
  end

  defp pixel(_x, y) when y < 24, do: <<31, 41, 55>>
  defp pixel(x, y) when x in 16..111 and y in 40..135, do: <<203, 213, 225>>
  defp pixel(x, y) when x in 128..223 and y in 44..51, do: <<75, 85, 99>>
  defp pixel(x, y) when x in 128..199 and y in 60..65, do: <<156, 163, 175>>
  defp pixel(x, y) when x in 128..223 and y in 112..131, do: <<22, 163, 74>>
  defp pixel(_x, _y), do: <<249, 250, 251>>

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  ## The summary

  defp summary(ctx, made, trial) do
    lines =
      for {_what, number, work_item} <- made do
        work_item = current(ctx.dana, work_item)
        version = Processes.version_for(work_item)
        stage = Processes.stage(version.document, work_item.stage_id)

        "  ##{number} #{work_item.title}: #{stage["name"]}, #{work_item.stage_state}, " <>
          "version #{version.number}"
      end

    Shell.info("""
    Trial version #{trial.number}, with one work item
    #{length(made)} work items:
    #{Enum.join(lines, "\n")}\
    """)
  end

  defp sign_in_lines do
    names =
      Enum.map_join([@owner | Enum.map(@people, &Tuple.delete_at(&1, 2))], "\n", fn
        {email, password} -> "  #{email}  #{password}"
      end)

    Shell.info("""

    Sign in at #{Apiary.Setup.public_url()}/users/log-in with a password:
    #{names}\
    """)
  end

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
