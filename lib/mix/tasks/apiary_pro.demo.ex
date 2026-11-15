defmodule Mix.Tasks.ApiaryPro.Demo do
  @shortdoc "Builds organisations and an operator, with months of runs (dev and test only)"

  @moduledoc """
  Builds the world of an instance with operators to review the console against at scale:
  organisations the owner owns and organisations they were invited to, people at every
  level, an operator, and months of runs in every organisation that has an owner. A development tool: it refuses to run in production.

      mix apiary_pro.demo
      mix apiary_pro.demo --owner someone@example.com --scale 0.5

  Run it where the instance has `managed_organisations`, which `QORY_FEATURES=all` turns
  on: an operator needs it. It acts as `--owner`, an instance admin: the instance
  organisation's first owner when it names none. What it makes goes through the edition's
  contexts, as the console's pages would, so the audit trail has it:

  - **At home**, the instance organisation's first workspace: three people who join it,
    none an owner, since its owners are the instance admins.
  - **Four organisations.** Vellorin Analytics and Quistral Studio, which the owner creates
    on Instance settings › Organisations (`ApiaryPro.Operators.create_organisation/2`);
    Ostrevane Robotics and Marrowick & Pend, which other people create from the switcher
    (`ApiaryPro.Organisations.create_organisation/2`) and invite the owner to, as an admin
    in the first and a member of two of its four workspaces in the second. Each has two to
    four workspaces.
  - **Twelve people**, confirmed, who join by invitation at every level, several of them
    in more than one organisation: a member's workspace is the one they were invited from
    and those they are added to (`ApiaryPro.WorkspaceAccess.add/3`); one membership is
    suspended, and a few invitations stay pending.
  - **An operator**, Zentrevo Works, which the owner creates and owns, with an admin and a
    member.
  - **Runs.** Every workspace of an organisation with an owner is filled by `mix apiary.demo.history`
    (`Mix.Tasks.Apiary.Demo.History`), in the name of its organisation's first owner, with
    a separate seed, size and span and without the task's people: 3,000 runs in 60
    repositories over 90 days at home, 300 to 1,500 in each workspace of the four
    organisations. `--scale` (1.0) multiplies the
    runs, ten at the least; `--skip-runs` leaves them out; `--concurrency` is handed on. A
    workspace with runs already is left as it is.
  - **Then**, in this order: Marrowick & Pend narrowed to observability by the instance
    (`ApiaryPro.Grants.set_organisation/3`); and the account of Marrowick & Pend's only
    owner suspended (`ApiaryPro.Suspensions`) and its ownership offered by the owner, as the
    arbiter, to its admin.

  The workspaces beyond each organisation's first are inserted as the tests' fixtures
  insert them, without an audit entry, rather than through
  `Apiary.Organisations.create_workspace/2`, which would need an owner's scope for each.
  It opens sign-up to organisations, for the people who create one, as an instance admin
  opens it on Instance settings › Configuration (`ApiaryPro.SignUp.save/2`), and it stays
  open after. While it runs, the task's node allows 1,000 invitations a day; the server's
  allowance is unchanged.

  Running it again finds what it made, the people by address, the organisations and
  workspaces by name, the memberships by person, and makes only what is missing; the
  arbitration and the suspension are made once.
  """

  use Mix.Task

  import Ecto.Query

  alias Apiary.{Accounts, Organisations, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Slug, Workspace}
  alias Apiary.Runs.Run
  alias ApiaryPro.{Grants, Operators, SignUp, Suspensions, Tenants}
  alias ApiaryPro.{Transfers, WorkspaceAccess}
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryPro.Transfers.Transfer
  alias Mix.Tasks.Apiary.Demo.History

  @switches [
    owner: :string,
    scale: :float,
    skip_runs: :boolean,
    concurrency: :integer
  ]

  @origin %{worker: "demo"}
  @invitations_per_day 1_000

  # The people, by the part of their address before @example.com.
  @people ~w(
    aisha.rahman bruno.costa chloe.martin dmitri.volkov farah.haddad gustav.lind
    hana.sato ines.moreau jakub.novak kofi.mensah lucia.romano mateo.garcia
  )

  # Home: the instance organisation's first workspace, its history as
  # {runs, repositories, days}, and who joins it, at which level.
  @home %{
    history: {3_000, 60, 90},
    people: [{"aisha.rahman", :admin}, {"jakub.novak", :member}, {"mateo.garcia", :member}]
  }

  # The organisations: who creates each, `:owner` for the task's owner; its workspaces as
  # {name, runs, repositories, days}, the first the one it is created with; who joins, as
  # {person, level, workspaces}, `:owner` for the task's owner, invited from the first of
  # their workspaces and added to the rest; and the addresses invited who have not joined.
  @organisations [
    %{
      name: "Vellorin Analytics",
      by: :owner,
      workspaces: [
        {"Main", 1_500, 60, 120},
        {"Data Platform", 900, 40, 90},
        {"Mobile", 600, 30, 75},
        {"Sandbox", 300, 15, 60}
      ],
      people: [
        {"aisha.rahman", :owner, ["Main"]},
        {"bruno.costa", :admin, ["Main"]},
        {"farah.haddad", :admin, ["Data Platform"]},
        {"chloe.martin", :member, ["Main", "Data Platform"]},
        {"dmitri.volkov", :member, ["Mobile", "Main"]},
        {"gustav.lind", :suspended, ["Main"]}
      ],
      invited: ["noor.aziz@example.com", "contractor@partner.example"]
    },
    %{
      name: "Quistral Studio",
      by: :owner,
      workspaces: [{"Main", 700, 25, 100}, {"Client Sites", 450, 20, 60}],
      people: [
        {"chloe.martin", :admin, ["Main"]},
        {"kofi.mensah", :member, ["Client Sites"]}
      ],
      invited: ["studio.intern@example.com"]
    },
    %{
      name: "Ostrevane Robotics",
      by: "hana.sato",
      workspaces: [
        {"Main", 1_200, 50, 110},
        {"Firmware", 800, 35, 120},
        {"Simulation", 500, 20, 90}
      ],
      people: [
        {:owner, :admin, ["Main"]},
        {"jakub.novak", :admin, ["Main"]},
        {"dmitri.volkov", :member, ["Simulation"]},
        {"mateo.garcia", :member, ["Firmware", "Main"]}
      ],
      invited: []
    },
    %{
      name: "Marrowick & Pend",
      by: "ines.moreau",
      workspaces: [
        {"Main", 900, 30, 90},
        {"Storefront", 650, 25, 70},
        {"Warehouse", 400, 18, 60},
        {"Analytics", 350, 15, 100}
      ],
      people: [
        {"kofi.mensah", :admin, ["Main"]},
        {:owner, :member, ["Main", "Storefront"]},
        {"lucia.romano", :member, ["Storefront", "Warehouse"]},
        {"mateo.garcia", :member, ["Main"]}
      ],
      invited: ["seasonal.help@example.com"]
    }
  ]

  @operator %{
    name: "Zentrevo Works",
    workspaces: [{"Main", 500, 20, 60}],
    people: [{"bruno.costa", :admin, ["Main"]}, {"lucia.romano", :member, ["Main"]}]
  }

  # The after-steps' subjects.
  @narrowed_organisation "Marrowick & Pend"
  @suspended_account "ines.moreau"
  @arbitrated_to "kofi.mensah"

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod,
      do: Mix.raise("mix apiary_pro.demo is a development tool: not in prod")

    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    # The query log of a world is millions of lines nobody asked for, from the start.
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")

    unless Apiary.Features.on?(:managed_organisations),
      do:
        Mix.raise(
          "the instance does not have managed_organisations: run it with QORY_FEATURES=all"
        )

    with_settings(fn ->
      world = world(owner!(opts[:owner]))

      if !opts[:skip_runs] do
        fill(world, Keyword.get(opts, :scale, 1.0), Keyword.get(opts, :concurrency, 6))
      end

      settle(world)
      summary(world)
    end)
  end

  # The setting of this node the world needs, put back after: the day's invitations.
  defp with_settings(fun) do
    keys = [:invitations_per_day]
    saved = for key <- keys, do: {key, Application.fetch_env(:apiary, key)}

    Application.put_env(
      :apiary,
      :invitations_per_day,
      max(Apiary.Instance.invitations_per_day(), @invitations_per_day)
    )

    try do
      fun.()
    after
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end
    end
  end

  ## The world

  defp world(owner) do
    instance =
      Tenants.instance_organisation() ||
        Mix.raise("there is no instance organisation yet: sign up first")

    instance_scope = scope!(owner, instance)

    if !Apiary.Access.instance_admin?(instance_scope),
      do: Mix.raise("#{owner.email} is no instance admin: name one with --owner")

    open_sign_up!(instance_scope)

    home = home_workspace!(instance, instance_scope)
    people = Map.new(@people, &{&1, person!(&1)})

    world = %{
      owner: owner,
      instance: instance,
      instance_scope: instance_scope,
      home: home,
      people: people
    }

    Mix.shell().info("Home: #{instance.slug}/#{home.slug}")

    for {person, level} <- @home.people do
      join!(world, instance, %{home.name => home}, owner, person, level, [home.name])
    end

    organisations =
      for spec <- @organisations, into: %{} do
        {spec.name, organisation!(world, spec)}
      end

    operator = operator!(world)
    Map.merge(world, %{organisations: organisations, operator: operator})
  end

  # Sign-up open to organisations, saved as the instance admin saves it, signed in now.
  defp open_sign_up!(instance_scope) do
    scope = put_in(instance_scope.user.authenticated_at, DateTime.utc_now())

    case SignUp.save(scope, %{"organisations" => "open"}) do
      {:ok, %{organisation: :open}} ->
        # This node's copy reads the row again before an organisation is created: the
        # save's broadcast reached it before this call does.
        if Process.whereis(SignUp.Cache), do: :sys.get_state(SignUp.Cache)
        :ok

      {:ok, _closed} ->
        Mix.raise("SIGNUP_ORGANISATIONS is closed: unset it, or set it to open")

      refused ->
        Mix.raise("sign-up was not opened: #{inspect(refused)}")
    end
  end

  defp owner!(nil) do
    instance =
      Tenants.instance_organisation() ||
        Mix.raise("there is no instance organisation yet: sign up first")

    first_owner(instance) || Mix.raise("#{instance.slug} has no owner")
  end

  defp owner!(email) do
    Accounts.get_user_by_email(email) || Mix.raise("there is no account #{email}")
  end

  defp organisation!(world, spec) do
    creator = if spec.by == :owner, do: world.owner, else: Map.fetch!(world.people, spec.by)

    organisation =
      find_organisation(spec.name) || create_organisation!(world, spec.by, creator, spec.name)

    workspaces = workspaces!(organisation, spec.workspaces)

    Mix.shell().info(
      "#{spec.name}: #{organisation.slug}, #{map_size(workspaces)} workspaces, created by #{creator.email}"
    )

    for {person, level, names} <- spec.people do
      join!(world, organisation, workspaces, creator, person, level, names)
    end

    main = workspaces |> Map.values() |> Enum.min_by(& &1.inserted_at, DateTime)

    for email <- spec.invited do
      invite_once!(creator, organisation, main, email)
    end

    %{organisation: organisation, creator: creator, workspaces: workspaces, spec: spec}
  end

  defp create_organisation!(world, :owner, _creator, name) do
    world.instance_scope
    |> Operators.create_organisation(%{"name" => name, "kind" => "organisation"})
    |> created!(name)
  end

  defp create_organisation!(_world, _by, creator, name) do
    creator
    |> Scope.for_user()
    |> Scope.put_origin(@origin)
    |> ApiaryPro.Organisations.create_organisation(%{"name" => name, "kind" => "organisation"})
    |> created!(name)
  end

  defp created!({:ok, %{organisation: organisation}}, _name), do: organisation
  defp created!(refused, name), do: Mix.raise("#{name} was not created: #{inspect(refused)}")

  defp operator!(world) do
    %{name: name} = @operator

    operator =
      find_organisation(name) ||
        world.instance_scope
        |> Operators.create_organisation(%{"name" => name, "kind" => "operator"})
        |> created!(name)

    if !Tenants.operator?(Tenants.put(operator)),
      do: Mix.raise("#{name} is there, and no operator")

    workspaces = workspaces!(operator, @operator.workspaces)

    for {person, level, names} <- @operator.people do
      join!(world, operator, workspaces, world.owner, person, level, names)
    end

    Mix.shell().info("#{name}: #{operator.slug}, an operator")
    %{organisation: operator, workspaces: workspaces, spec: @operator}
  end

  ## People and memberships

  defp person!(name), do: user!("#{name}@example.com")

  defp user!(email), do: Accounts.get_user_by_email(email) || register!(email)

  # An account, confirmed as its first sign-in by email confirms it.
  defp register!(email) do
    user = %{email: email} |> Accounts.register_user() |> ok!("#{email} was not registered")

    case capture(&Accounts.deliver_login_instructions(user, &1)) do
      {_sent, token} when is_binary(token) ->
        {user, _expired} =
          token |> Accounts.login_user_by_magic_link() |> ok!("#{email} was not confirmed")

        user

      {refused, nil} ->
        Mix.raise("no sign-in link was made for #{email}: #{inspect(refused)}")
    end
  end

  # The person joins `organisation` by an invitation from `inviter`, sent from the first of
  # `names`, the workspaces they are added to; then `inviter` makes them `level`. A person
  # who is a member already is left as they are.
  defp join!(world, organisation, workspaces, inviter, person, level, [first | rest]) do
    user = if person == :owner, do: world.owner, else: Map.fetch!(world.people, person)

    if !membership(organisation, user) do
      scope = scope!(inviter, organisation, Map.fetch!(workspaces, first))
      token = invite!(scope, user.email)
      membership = accept!(user, token, "the invitation to #{organisation.slug}")

      if level in [:member, :suspended] do
        for name <- rest do
          scope
          |> WorkspaceAccess.add(membership.id, Map.fetch!(workspaces, name).id)
          |> ok!("#{user.email} was not added to #{name}")
        end
      end

      case level do
        :member ->
          :ok

        :suspended ->
          scope
          |> Organisations.suspend_member(membership.id)
          |> ok!("#{user.email} was not suspended")

        level ->
          scope
          |> Organisations.set_member_level(membership.id, level)
          |> ok!("#{user.email} was not made #{level}")
      end
    end
  end

  defp accept!(%User{} = user, token, what) do
    user
    |> Scope.for_user()
    |> Scope.put_origin(@origin)
    |> Organisations.accept_invitation(token)
    |> ok!("#{user.email} did not accept #{what}")
  end

  defp invite!(scope, email) do
    case capture(&Organisations.invite_member(scope, %{"email" => email}, &1)) do
      {{:ok, _invitation}, token} when is_binary(token) ->
        token

      {refused, _token} ->
        Mix.raise("#{email} was not invited to #{scope.organisation.slug}: #{inspect(refused)}")
    end
  end

  # An invitation from `inviter` to an address the organisation has not invited yet. The
  # inviter's scope is asked for only then: on a second run, the inviter may be suspended.
  defp invite_once!(inviter, %Organisation{id: id} = organisation, workspace, email) do
    invited? =
      Repo.exists?(from i in Invitation, where: i.organisation_id == ^id and i.email == ^email)

    if !invited?, do: invite!(scope!(inviter, organisation, workspace), email)
  end

  # The token a mail would have carried, handed to the URL function instead of sent:
  # `{what fun returned, token}`, the token nil when no URL was asked for.
  defp capture(fun) do
    ref = make_ref()
    parent = self()

    result =
      fun.(fn token ->
        send(parent, {ref, token})
        "#{ApiaryWeb.Endpoint.url()}/demo/#{token}"
      end)

    receive do
      {^ref, token} -> {result, token}
    after
      0 -> {result, nil}
    end
  end

  ## Finding what is there

  defp find_organisation(name) do
    Repo.one(
      from o in Organisation,
        where: o.name == ^name and is_nil(o.deletion_marked_at),
        order_by: [asc: o.inserted_at, asc: o.id],
        limit: 1
    )
  end

  defp first_owner(organisation), do: first_at(organisation, :owner)

  defp first_at(%Organisation{id: id}, level) do
    Repo.one(
      from m in Membership,
        join: u in assoc(m, :user),
        where: m.organisation_id == ^id and m.level == ^level,
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: 1,
        select: u
    )
  end

  defp membership(%Organisation{id: organisation_id}, %User{id: user_id}),
    do: Repo.get_by(Membership, organisation_id: organisation_id, user_id: user_id)

  # The instance's first workspace. An instance that is set up and has none yet, as it is
  # after its set-up link, gets Main, a software workspace, made by `scope` as the
  # workspace set-up page makes it.
  defp home_workspace!(%Organisation{} = instance, scope) do
    if !Organisations.has_workspace?(instance),
      do: ok!(Organisations.create_first_workspace(scope, %{"domain" => "software"}), "Main")

    first_workspace!(instance)
  end

  defp first_workspace!(%Organisation{id: id} = organisation) do
    Repo.one(
      from w in Workspace,
        where: w.organisation_id == ^id and is_nil(w.deletion_marked_at),
        order_by: [asc: w.inserted_at, asc: w.id],
        limit: 1
    ) || Mix.raise("#{organisation.slug} has no workspace")
  end

  # The workspaces of `specs`, by name: those the organisation has, the others inserted.
  defp workspaces!(organisation, specs) do
    Map.new(specs, fn {name, _runs, _repositories, _days} ->
      {name, workspace!(organisation, name)}
    end)
  end

  defp workspace!(%Organisation{id: id} = organisation, name) do
    Repo.one(
      from w in Workspace,
        where: w.organisation_id == ^id and w.name == ^name and is_nil(w.deletion_marked_at),
        order_by: [asc: w.inserted_at, asc: w.id],
        limit: 1
    ) || insert_workspace!(organisation, name)
  end

  # As the tests' fixtures insert one, without an entry; the product's way is
  # `Apiary.Organisations.create_workspace/2`.
  defp insert_workspace!(%Organisation{id: id}, name) do
    taken? = fn slug ->
      Repo.exists?(from w in Workspace, where: w.organisation_id == ^id and w.slug == ^slug)
    end

    slug =
      Slug.pick(Slug.from_name(name, "workspace"), ApiaryWeb.ReservedSlugs.workspace(), taken?)

    %Workspace{organisation_id: id}
    |> Workspace.create_changeset(%{name: name, domain: "software"})
    |> Workspace.put_slug(slug)
    |> Repo.insert!()
  end

  defp scope!(%User{} = user, %Organisation{} = organisation, workspace \\ nil) do
    case Organisations.resolve_scope(
           Scope.for_user(user),
           organisation.slug,
           workspace && workspace.slug
         ) do
      {:ok, scope} ->
        Scope.put_origin(scope, @origin)

      :error ->
        Mix.raise("#{user.email} does not reach #{organisation.slug}")
    end
  end

  defp ok!({:ok, value}, _what), do: value
  defp ok!(refused, what), do: Mix.raise("#{what}: #{inspect(refused)}")

  ## Runs

  defp fill(world, scale, concurrency) do
    plan = fills(world)
    Mix.shell().info("\nFilling #{length(plan)} workspaces")

    for {organisation, workspace, {runs, repositories, days}, seed} <- plan do
      if Repo.exists?(from r in Run, where: r.workspace_id == ^workspace.id) do
        Mix.shell().info("#{organisation.slug}/#{workspace.slug} has runs: left as it is")
      else
        runs = max(round(runs * scale), 10)

        History.run([
          "--workspace",
          "#{organisation.slug}/#{workspace.slug}",
          "--runs",
          "#{runs}",
          "--repositories",
          "#{min(repositories, runs)}",
          "--days",
          "#{days}",
          "--seed",
          "#{seed}",
          "--concurrency",
          "#{concurrency}",
          "--skip-members"
        ])
      end
    end
  end

  # Every workspace with an owner, with its history and a separate seed.
  defp fills(world) do
    home = [{world.instance, world.home, @home.history, 1}]

    organisations =
      (@organisations ++ [@operator])
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {spec, i} ->
        %{organisation: organisation, workspaces: workspaces} = organisation_of(world, spec.name)

        for {{name, runs, repositories, days}, j} <- Enum.with_index(spec.workspaces) do
          {organisation, Map.fetch!(workspaces, name), {runs, repositories, days}, 100 * i + j}
        end
      end)

    home ++ organisations
  end

  defp organisation_of(world, name) do
    if name == @operator.name,
      do: world.operator,
      else: Map.fetch!(world.organisations, name)
  end

  ## After the world

  defp settle(world) do
    Mix.shell().info("")
    grants(world)
    arbitration(world)
  end

  defp grants(world) do
    organisation = Map.fetch!(world.organisations, @narrowed_organisation).organisation

    world.instance_scope
    |> Grants.set_organisation(organisation.id, [:observability])
    |> ok!("#{@narrowed_organisation} was not narrowed")

    Mix.shell().info("Narrowed to observability: #{@narrowed_organisation}")
  end

  # The only owner of the organisation they created suspended, and its ownership offered by
  # the owner, as the arbiter, to its admin.
  defp arbitration(world) do
    suspended = Map.fetch!(world.people, @suspended_account)
    admin = Map.fetch!(world.people, @arbitrated_to)

    organisation =
      world.organisations
      |> Map.values()
      |> Enum.find(&(&1.spec.by == @suspended_account))
      |> Map.fetch!(:organisation)

    world.instance_scope
    |> Suspensions.suspend_account(suspended.id)
    |> ok!("#{suspended.email} was not suspended")

    if Repo.exists?(from t in Transfer, where: t.organisation_id == ^organisation.id) do
      Mix.shell().info("#{suspended.email} suspended; #{organisation.name} has an offer already")
    else
      world.instance_scope
      |> Transfers.arbitrate(
        organisation.id,
        membership(organisation, admin).id,
        "Its only owner's account is suspended while their access is reviewed; the admin keeps the organisation running meanwhile."
      )
      |> ok!("#{organisation.name} was not offered to #{admin.email}")

      Mix.shell().info(
        "#{suspended.email} suspended; #{organisation.name} offered to #{admin.email} by the arbiter"
      )
    end
  end

  ## What there is now

  defp summary(world) do
    tenants = Repo.all(from t in Tenant, select: t.kind)
    count = &Repo.aggregate(&1, :count)
    [[size]] = Repo.query!("SELECT pg_size_pretty(pg_database_size(current_database()))").rows

    held =
      Repo.aggregate(from(m in Membership, where: m.user_id == ^world.owner.id), :count)

    Mix.shell().info("""

    Organisations  #{length(tenants)}: #{Enum.count(tenants, &(&1 == :organisation))} organisations, \
    #{Enum.count(tenants, &(&1 == :operator))} operators
    Workspaces     #{count.(Workspace)}
    People         #{count.(User)}, in #{count.(Membership)} memberships; #{world.owner.email} in #{held}
    Runs           #{count.(Run)}, #{count.(Apiary.Runs.Event)} events
    Audit entries  #{count.(Apiary.Audit.Entry)}
    Database       #{size}

    #{ApiaryWeb.Endpoint.url()}/#{world.instance.slug}/#{world.home.slug}/runs\
    """)
  end
end
