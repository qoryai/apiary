defmodule ApiaryWeb.RefusalsCase do
  @moduledoc """
  RefusalsCase is the refusals test as data: every change the pages offer, sent through the
  web layer by someone who may not make it, one row per attempt. The page is mounted as
  that person and the event sent as the browser would, with params the page itself would
  never send when it hides the control. Each row asserts three things: it is refused,
  nothing of the organisation changed in the database, and no audit entry was written.

  A module of rows gives, for its edition, its actors, how to make them and the places and
  things its rows name, and a row per attempt. `use`d with the rows modules of the core and
  of an edition, in that order:

      use ApiaryWeb.RefusalsCase, rows: [ApiaryWeb.RefusalsRows, MyEditionWeb.RefusalsRows]

  it generates one test per row, and a test that fails for an action of `Apiary.Access`
  that changes something and has neither a row nor an exemption that says why. `covers:`
  says which actions that is, as `Apiary.AccessCase`'s does (`Apiary.AccessCase.actions/1`):
  `:all`, the default, every action; `:core`, the core's own. The core's own test is `use
  ApiaryWeb.RefusalsCase, rows: [ApiaryWeb.RefusalsRows], covers: :core`; an edition's
  gives the core's rows and its own and covers every action, which sends the core's rows
  again, under the edition.

  A row is `{action, actor, page, event, params}`, or the same with options last. `page`
  is a path, where `:name` is a value of the world (`value/2`); in `params`, an atom is.
  The answers, `answer:`:

    * `:refused` (the default): the page says no: an error flash, the policy's write
      error, or a redirect with an error flash;
    * `:not_found`: the page answers as it does when every id the row carries is replaced
      by one that exists nowhere: whether the thing exists is not told; the page stays up;
    * `:not_found_at_mount`: a path that names another place's row, or an organisation or
      a page out of the person's reach: it answers 404 as it opens, as it does for an id
      that exists nowhere, and no event is sent;
    * `:refused_at_mount`: the page refuses as it opens, with a redirect or an alert,
      before any event: a row that means the event's refusal is `:refused`, which fails for
      a page that did not open without an alert;
    * `:ignored`: the page drops the event: no flash, no write error, no redirect.

  The other options: `needs:`, the feature the row needs beside its action's; `prelude:`,
  events sent first, as the actor, to open a dialog, `[{event, params}]`; `meanwhile:`, a
  change made after the page opened (`c:meanwhile/2`); `setup:`, a change made before the
  page opens (`c:before_page/2`). An actor may be changed after the page opened too, by
  its own name: the change is made in the database directly, without the broadcast an open
  page follows, so the event arrives before the page hears of it, and what the page's
  scope still allows is asked again by the context function
  (`Apiary.Access.authorize/3`).

  Besides the rows of the organisations a module watches (`c:watched/1`), in every table
  that holds one, a row asserts that no organisation on the instance was created, changed
  or removed, that no audit entry was written anywhere, that no job was enqueued for a
  watched organisation, and that no email was sent.

  The tests are not async: an edition's rows may write through the instance's own
  organisation, committed once outside the sandbox, whose row and owners they lock
  (docs/conventions.md, Tests).
  """

  use ExUnit.CaseTemplate

  import Ecto.Query
  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Apiary.Accounts.User
  alias Apiary.Organisations.Organisation
  alias Apiary.Repo

  @endpoint ApiaryWeb.Endpoint

  @answers [:refused, :not_found, :not_found_at_mount, :refused_at_mount, :ignored]
  @options [:answer, :needs, :prelude, :meanwhile, :setup]

  @typedoc "A row as a rows module writes it."
  @type row ::
          {Apiary.Access.action(), atom, String.t(), String.t(), map}
          | {Apiary.Access.action(), atom, String.t(), String.t(), map, keyword}

  @typedoc "The world the rows modules make, by name."
  @type world :: %{atom => term}

  @doc "The module's actors."
  @callback actors() :: [atom]

  @doc "The module's rows."
  @callback rows() :: [row]

  @doc """
  The actions no row of the module is for, by why: `%{reason => [action]}`. An exemption
  stands until a later module's rows are for its action, as an edition's page offers what
  the core's pages do not.
  """
  @callback exempt() :: %{atom => [Apiary.Access.action()]}

  @doc """
  Given the world the modules before it made, the names the module adds: the places and
  things its rows name, and, under each of its actors' names, the person that actor signs
  in as, a map with `user`.
  """
  @callback setup(world) :: world

  @doc """
  The value of `name` in a path or in params: a slug or a text, `{:id, id}` for an id,
  which a `:not_found` row's twin replaces with one that exists nowhere, or nil for a name
  that is not the module's.
  """
  @callback value(name :: atom, world) :: String.t() | {:id, term} | nil

  @doc """
  The organisations of the world whose rows a row asserts unchanged, in every table that
  holds one, and the accounts; nil for one the world does not have.
  """
  @callback watched(world) :: [%Organisation{} | %User{} | nil]

  @doc """
  Makes the change a row's `setup:` names, before the page opens, if it is the module's:
  `:ok`, or nil for a change that is not. The row's twin makes it again, in the same world:
  a change made already is not made twice.
  """
  @callback before_page(step :: atom, world) :: :ok | nil

  @doc """
  Makes a change after the page opened, if it is the module's: an actor's own, by their
  name, or the one a row's `meanwhile:` names. `:ok`, or nil for a change that is not. Every
  module is asked for an actor; a row's `meanwhile:` must be some module's.
  """
  @callback meanwhile(step :: term, world) :: :ok | nil

  using opts do
    modules = Keyword.fetch!(opts, :rows)
    covers = Keyword.get(opts, :covers, :all)

    quote bind_quoted: [modules: modules, covers: covers] do
      use ApiaryWeb.ConnCase, async: false

      @refusals_modules modules
      @refusals_covers covers

      for {row, n} <- Enum.with_index(ApiaryWeb.RefusalsCase.rows(modules), 1) do
        @tag refusal: row, needs: row.needs, capture_log: row.answer == :not_found_at_mount
        test "#{n}. #{row.action}: #{row.actor} sends #{row.event} on #{row.page}, #{row.answer}",
             ctx do
          ApiaryWeb.RefusalsCase.assert_row(ctx.refusal, @refusals_modules)
        end
      end

      test "every row names an action of the file, an actor of its modules, and a known answer" do
        ApiaryWeb.RefusalsCase.assert_rows(@refusals_modules, @refusals_covers)
      end

      test "every action that changes something has a row, or an exemption that says why" do
        ApiaryWeb.RefusalsCase.assert_covered(@refusals_modules, @refusals_covers)
      end
    end
  end

  @doc """
  rows/1 is the rows of `modules`, in their order, each a map: `action`, `actor`, `page`,
  `event`, `params`, `opts`, and from the options `answer` and `needs`, the row's feature
  or its action's.
  """
  @spec rows([module]) :: [map]
  def rows(modules) do
    for module <- modules, row <- module.rows() do
      {action, actor, page, event, params, opts} =
        case row do
          {action, actor, page, event, params} -> {action, actor, page, event, params, []}
          {_, _, _, _, _, _} = row -> row
        end

      %{
        action: action,
        actor: actor,
        page: page,
        event: event,
        params: params,
        opts: opts,
        answer: Keyword.get(opts, :answer, :refused),
        needs: Keyword.get(opts, :needs, Apiary.Access.feature(action))
      }
    end
  end

  @doc "actors/1 is the actors of `modules`, in their order."
  @spec actors([module]) :: [atom]
  def actors(modules), do: Enum.flat_map(modules, & &1.actors())

  @doc """
  exempt/1 is the actions of `modules` no row is for: each module's exemptions, less the
  actions a later module's rows are for.
  """
  @spec exempt([module]) :: [Apiary.Access.action()]
  def exempt(modules) do
    Enum.reduce(modules, [], fn module, exempt ->
      rowed = Enum.map(module.rows(), &elem(&1, 0))
      Enum.uniq((exempt -- rowed) ++ (module.exempt() |> Map.values() |> List.flatten()))
    end)
  end

  @doc """
  world/1 makes the world of `modules`, each given what the ones before it made
  (`c:setup/1`).
  """
  @spec world([module]) :: world
  def world(modules) do
    Enum.reduce(modules, %{}, fn module, world -> Map.merge(world, module.setup(world)) end)
  end

  @doc """
  assert_rows/2 asserts that every row of `modules` names an action of what the file
  covers, an actor of the modules, an answer of the case and only its options.
  """
  @spec assert_rows([module], :all | :core) :: :ok
  def assert_rows(modules, covers) do
    actions = Apiary.AccessCase.actions(covers)
    actors = actors(modules)

    for row <- rows(modules) do
      assert row.action in actions, "#{inspect(row)} names an action the file does not cover"
      assert row.actor in actors, "#{inspect(row)} names an actor of no module"
      assert row.answer in @answers, "#{inspect(row)} gives an answer that is none"
      assert Keyword.keys(row.opts) -- @options == [], "#{inspect(row)} has an unknown option"
    end

    assert actors == Enum.uniq(actors), "an actor is named by two modules"
    :ok
  end

  @doc """
  assert_covered/2 asserts that every action of what the file covers
  (`Apiary.AccessCase.actions/1`) has a row of `modules`, or an exemption, and that every
  exemption names an action it covers and no row is for.
  """
  @spec assert_covered([module], :all | :core) :: :ok
  def assert_covered(modules, covers) do
    actions = Apiary.AccessCase.actions(covers)
    rowed = MapSet.new(rows(modules), & &1.action)
    exempt = exempt(modules)

    missing = for action <- actions, action not in rowed, action not in exempt, do: action

    assert missing == [], "actions without a row: #{inspect(missing)}"
    assert exempt -- actions == [], "exemptions of actions the file does not cover"
    assert Enum.filter(exempt, &(&1 in rowed)) == [], "exemptions of actions with a row"
    :ok
  end

  @doc """
  assert_row/2 makes the world of `modules`, sends the row's attempt as its actor, and
  asserts the row's answer, that nothing watched changed, and that no email was sent.
  """
  @spec assert_row(map, [module]) :: :ok
  def assert_row(row, modules) do
    world = world(modules)
    outcome = attempt(modules, world, row, & &1)
    assert_answer(modules, row, outcome, world)
    :ok
  end

  @doc """
  person/2 is a person in the scope's workspace, who joined as a member and was given
  `level` by the scope's person, an owner: `%{user: user, membership: membership}`.
  """
  @spec person(Apiary.Accounts.Scope.t(), Apiary.Edition.level()) :: map
  def person(owner, level) do
    %{user: user, membership: membership} = Apiary.OrganisationsFixtures.member_fixture(owner)

    if level != :member,
      do: {:ok, _} = Apiary.Organisations.set_member_level(owner, membership.id, level)

    %{user: user, membership: Repo.get!(Apiary.Organisations.Membership, membership.id)}
  end

  @doc """
  put_level/2 gives the person's membership `level` in the database, without the broadcast
  an open page follows, and without telling the edition: the membership as it is after.
  """
  @spec put_level(%{membership: map}, Apiary.Edition.level()) :: map
  def put_level(%{membership: membership}, level) do
    {1, [changed]} =
      Repo.update_all(
        from(m in Apiary.Organisations.Membership, where: m.id == ^membership.id, select: m),
        set: [level: level]
      )

    changed
  end

  ## The attempt

  defp attempt(modules, world, row, ids) do
    Process.flag(:trap_exit, true)
    if step = row.opts[:setup], do: change!(modules, :before_page, step, world)

    conn = ApiaryWeb.ConnCase.log_in_user(build_conn(), Map.fetch!(world, row.actor).user)
    path = fill(modules, row.page, world, ids)

    case mount(conn, path) do
      {:ok, lv} ->
        for {event, params} <- row.opts[:prelude] || [],
            do: {:ok, _} = send_event(lv, event, resolve(modules, params, world, ids))

        for module <- modules, do: module.meanwhile(row.actor, world)
        if step = row.opts[:meanwhile], do: change!(modules, :meanwhile, step, world)

        alerts = alerts(lv)
        before = snapshot(modules, world)
        flush_emails()
        result = send_event(lv, row.event, resolve(modules, row.params, world, ids))
        after_ = snapshot(modules, world)

        assert_unchanged(before, after_)
        refute_email_sent()
        outcome(lv, alerts, result)

      {:refused, outcome} ->
        {:at_mount, outcome}
    end
  end

  # A change a row names is some module's.
  defp change!(modules, fun, step, world) do
    made = for module <- modules, apply(module, fun, [step, world]) == :ok, do: module
    assert made != [], "no rows module makes #{inspect(step)} (#{fun})"
  end

  # The page opened, or what it answered instead: a redirect with its flash, the exception
  # it raised, a path out of reach, or the 404 the path scope sends for an organisation
  # the person does not reach, before any page mounts.
  defp mount(conn, path) do
    case unreached(conn, path) do
      true -> {:refused, {:status, 404}}
      false -> open(conn, path)
    end
  end

  defp unreached(conn, path) do
    get(conn, path).status == 404
  rescue
    _raised -> false
  end

  defp open(conn, path) do
    case live(conn, path) do
      {:ok, lv, _html} -> {:ok, lv}
      {:error, {kind, %{to: to, flash: flash}}} -> {:refused, {kind, to, flash["error"]}}
    end
  rescue
    error -> {:refused, {:raised, exception(error)}}
  end

  defp send_event(lv, event, params) do
    {:ok, render_click(lv, event, params)}
  catch
    :exit, {{reason, stacktrace}, _call} ->
      {:crashed, exception(Exception.normalize(:error, reason, stacktrace))}
  end

  defp exception(%Plug.Conn.WrapperError{reason: reason}), do: exception(reason)
  defp exception(%module{}), do: module

  # What the page answered, as a person would see it: where it sent them and with what
  # error, or the alerts it shows, before the event and after, or that it ended.
  defp outcome(_lv, _alerts, {:crashed, module}), do: {:crashed, module}

  defp outcome(lv, _alerts, {:ok, {:error, {kind, %{to: to}}}}) do
    {kind, to, assert_redirect(lv, to)["error"]}
  end

  defp outcome(lv, alerts, {:ok, html}) when is_binary(html), do: {:page, alerts, alerts(lv)}

  # The alerts the page shows: an error flash, the policy's write error, a refusal in the
  # composer. The flashes of a lost connection are there all along, hidden.
  defp alerts(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[role=alert]:not([hidden])")
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.map(&String.trim/1)
    |> Enum.sort()
  end

  defp assert_answer(_modules, %{answer: :refused} = row, outcome, _world) do
    assert refused?(outcome), "#{inspect(row)} was not refused: #{inspect(outcome)}"
  end

  defp assert_answer(modules, %{answer: :not_found} = row, outcome, world) do
    refute match?({kind, _} when kind in [:crashed, :raised], outcome),
           "#{inspect(row)} ended the page: #{inspect(outcome)}"

    # The page opened and was sent the event: a twin that fails as it opens too proves
    # nothing.
    refute match?({:at_mount, _}, outcome),
           "#{inspect(row)} did not open: #{inspect(outcome)}"

    assert_twin(modules, row, outcome, world)
  end

  defp assert_answer(modules, %{answer: :not_found_at_mount} = row, outcome, world) do
    case outcome do
      {:at_mount, {:status, status}} -> assert status == 404
      {:at_mount, {:raised, module}} -> assert Plug.Exception.status(struct(module)) == 404
      other -> flunk("#{inspect(row)} opened: #{inspect(other)}")
    end

    assert_twin(modules, row, outcome, world)
  end

  defp assert_answer(_modules, %{answer: :refused_at_mount} = row, outcome, _world) do
    assert refused_at_mount?(outcome),
           "#{inspect(row)} was not refused as the page opened: #{inspect(outcome)}"
  end

  defp assert_answer(_modules, %{answer: :ignored} = row, outcome, _world) do
    assert match?({:page, alerts, alerts}, outcome),
           "#{inspect(row)} was not ignored: #{inspect(outcome)}"
  end

  # The same attempt with every id one that exists nowhere, in the same world, which the
  # first attempt left as it was.
  defp assert_twin(modules, row, outcome, world) do
    twin = attempt(modules, world, row, fn _id -> Ecto.UUID.generate() end)

    assert outcome == twin,
           "#{inspect(row)} answered #{inspect(outcome)}, and #{inspect(twin)} for ids that " <>
             "exist nowhere"
  end

  # Refused by the event: the page opened without an alert, and the event brought one, or
  # sent the person away with an error. A page that refused as it opened, with a redirect
  # or an alert, never asked the server about the event: that is `refused_at_mount`.
  defp refused?({:page, [], after_}), do: after_ != []
  defp refused?({kind, _to, flash}) when kind in [:redirect, :live_redirect], do: is_binary(flash)
  defp refused?(_outcome), do: false

  defp refused_at_mount?({:at_mount, {kind, _to, flash}})
       when kind in [:redirect, :live_redirect],
       do: is_binary(flash)

  defp refused_at_mount?({:page, [_ | _], _after}), do: true
  defp refused_at_mount?(_outcome), do: false

  ## The values a row names

  # Slugs and texts in a path, ids in params. `ids` maps an id, for the twin of a
  # `:not_found` row.
  defp value(modules, name, world, ids) do
    case Enum.find_value(modules, & &1.value(name, world)) do
      nil -> raise ArgumentError, "no rows module knows #{inspect(name)}"
      {:id, id} -> ids.(id)
      value -> value
    end
  end

  defp fill(modules, template, world, ids) do
    Regex.replace(~r/:(\w+)/, template, fn _, name ->
      modules |> value(String.to_existing_atom(name), world, ids) |> to_string()
    end)
  end

  defp resolve(modules, params, world, ids) when is_map(params),
    do: Map.new(params, fn {key, value} -> {key, resolve(modules, value, world, ids)} end)

  defp resolve(modules, list, world, ids) when is_list(list),
    do: Enum.map(list, &resolve(modules, &1, world, ids))

  defp resolve(modules, name, world, ids) when is_atom(name), do: value(modules, name, world, ids)
  defp resolve(_modules, value, _world, _ids), do: value

  ## Nothing changed

  # Every row of the watched organisations, in every table that holds one, the audit trail
  # included, and the jobs enqueued for them; the watched accounts; every organisation of
  # the instance; every audit entry.
  defp snapshot(modules, world) do
    watched =
      modules
      |> Enum.flat_map(& &1.watched(world))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    organisations = for %Organisation{} = organisation <- watched, do: organisation
    accounts = for %User{} = user <- watched, do: user

    rows =
      for table <- ["organisations" | Apiary.Deletion.Tables.tables()],
          organisation <- organisations,
          into: %{} do
        column = if table == "organisations", do: "id", else: "organisation_id"

        {"#{table} of #{organisation.id}",
         rows(
           "SELECT to_jsonb(t)::text FROM #{table} t WHERE #{column} = $1",
           Ecto.UUID.dump!(organisation.id)
         )}
      end

    jobs =
      for organisation <- organisations, into: %{} do
        {"oban_jobs of #{organisation.id}",
         rows(
           "SELECT to_jsonb(j)::text FROM oban_jobs j WHERE j.args->>'organisation_id' = $1",
           organisation.id
         )}
      end

    accounts =
      for user <- accounts, into: %{} do
        {"the account #{user.id}",
         rows("SELECT to_jsonb(u)::text FROM users u WHERE u.id = $1", Ecto.UUID.dump!(user.id))}
      end

    rows
    |> Map.merge(jobs)
    |> Map.merge(accounts)
    |> Map.put("every organisation", rows("SELECT to_jsonb(o)::text FROM organisations o", nil))
    |> Map.put("every audit entry", rows("SELECT e.id::text FROM audit_entries e", nil))
  end

  defp rows(sql, nil) do
    %{rows: rows} = Repo.query!(sql <> " ORDER BY 1", [])
    rows
  end

  defp rows(sql, param) do
    %{rows: rows} = Repo.query!(sql <> " ORDER BY 1", [param])
    rows
  end

  # The emails the world's fixtures sent, so that one the event sends is seen.
  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp assert_unchanged(before, after_) do
    assert length(after_["every audit entry"]) == length(before["every audit entry"]),
           "an audit entry was written"

    for {table, rows} <- before do
      assert after_[table] == rows, "#{table} changed"
    end
  end
end
