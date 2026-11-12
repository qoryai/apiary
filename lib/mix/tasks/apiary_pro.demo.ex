defmodule Mix.Tasks.ApiaryPro.Demo do
  @shortdoc "Builds organisations, an operator and its clients, with months of runs (dev and test only)"

  @moduledoc """
  Builds the world of an instance with operators to review the console against at scale:
  organisations the owner owns and organisations they were invited to, people at every
  level, an operator with its clients, and months of runs in every organisation that has
  an owner. A development tool: it refuses to run in production.

      mix apiary_pro.demo
      mix apiary_pro.demo --owner someone@example.com --clients 20 --scale 0.5

  Run it where the instance has `managed_organisations` and `security`, which
  `QORY_FEATURES=all` turns on: an operator and its clients need `managed_organisations`,
  and policy requests `security`. It acts as `--owner`, an instance admin: the instance
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
    member, and `--clients` (50) clients the owner creates
    (`ApiaryPro.Operators.create_client/3`), each inviting its first owner. Every sixth
    stays without an owner, its invitation pending, and without a workspace; the others'
    owners accept, and their clients get Main and none to two workspaces more.
  - **Runs.** Every workspace of an organisation with an owner is filled by `mix apiary.demo.history`
    (`Mix.Tasks.Apiary.Demo.History`), in the name of its organisation's first owner, with
    a separate seed, size and span and without the task's people: 3,000 runs in 60
    repositories over 90 days at home, 300 to 1,500 in each workspace of the four
    organisations, and 30 to 200 in each of a client's. `--scale` (1.0) multiplies the
    runs, ten at the least; `--skip-runs` leaves them out; `--concurrency` is handed on. A
    workspace with runs already is left as it is.
  - **Then**, in this order: Marrowick & Pend narrowed to observability by the instance
    (`ApiaryPro.Grants.set_organisation/3`), and three clients by the operator
    (`ApiaryPro.Grants.set_client/3`); three policy requests from the operator to clients
    with the security policy (`ApiaryPro.PolicyRequests`), the first answered by some,
    accepted or declined, the second withdrawn after a few accepted it, the third
    unanswered; the account of Marrowick & Pend's only owner suspended
    (`ApiaryPro.Suspensions`) and its ownership offered by the owner, as the arbiter, to
    its admin; and one client suspended.

  The workspaces beyond each organisation's first are inserted as the tests' fixtures
  insert them, without an audit entry, rather than through
  `Apiary.Organisations.create_workspace/2`, which would need an owner's scope for each.
  It opens sign-up to organisations, for the people who create one, as an instance admin
  opens it on Instance settings › Configuration (`ApiaryPro.SignUp.save/2`), and it stays
  open after. While it runs, the task's node allows 1,000 invitations a day, which the
  operator's invitations of its clients' owners count against; the server's allowance is
  unchanged.

  Running it again finds what it made, the people by address, the organisations and
  workspaces by name, the memberships by person, and makes only what is missing; the
  policy requests, the offer, the arbitration and the suspensions are made once.
  """

  use Mix.Task

  import Ecto.Query

  alias Apiary.{Accounts, Organisations, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Slug, Workspace}
  alias Apiary.Runs.Run
  alias ApiaryPro.{Grants, Operators, PolicyRequests, SignUp, Suspensions, Tenants}
  alias ApiaryPro.{Transfers, WorkspaceAccess}
  alias ApiaryPro.PolicyRequests.{Answer, Request}
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryPro.Transfers.Transfer
  alias Mix.Tasks.Apiary.Demo.History

  @switches [
    owner: :string,
    clients: :integer,
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

  @clients [
    "Abrevan Freight",
    "Allomere Insurance",
    "Belquist Books",
    "Blusquerin Logistics",
    "Brisolde Clinics",
    "Calvoran Engineering",
    "Cindravel Games",
    "Corrumbe Mobility",
    "Corvalith Ledger",
    "Cuspinel Security",
    "Dravelin Travel",
    "Elsquorn Energy",
    "Emberquist Foods",
    "Fallowrin Bank",
    "Fennorek Farms",
    "Fiddlequarn Realty",
    "Fosquelle Pharma",
    "Glimmarin Media",
    "Grevaunt Aerospace",
    "Harrowquel Shipping",
    "Hazquorin Retail",
    "Hesperolt Schools",
    "Irvantel Construction",
    "Jadquerel Telecom",
    "Kestovan Payments",
    "Kittrelune Water",
    "Lanquoril Labs",
    "Larvesse Fashion",
    "Marquelon Hotels",
    "Meddravel Music",
    "Millquarn Dairy",
    "Morvassel Outdoor",
    "Nettravik Research",
    "Northvalm Pensions",
    "Oakquirrel Mining",
    "Orchavel Grocers",
    "Pebrolin Surf",
    "Quillavant Publishing",
    "Ravquenel Studios",
    "Redquorin Automotive",
    "Salmeroth Brewing",
    "Silvarunde Care",
    "Skelloran Drones",
    "Stonquavel Analytics",
    "Thistrevan Bakery",
    "Tidquarrel Ports",
    "Umbravelt Textiles",
    "Wrenquiss Robotics",
    "Willamorve Wines",
    "Yarquelin Biotech"
  ]
  @client_workspaces ["Staging", "Internal Tools", "Data", "Mobile", "Platform", "Web"] ++
                       ["Tooling", "Research"]
  @first_names ~w(maria tomas yuki omar ingrid ravi zoe felix amelia diego nina oskar leila hugo sana piotr)
  @last_names ~w(okafor lindqvist tanaka mbeki berg iyer fischer laurent castillo horvat ahmed kowalski silva brennan duarte wu)

  # What the operator asks its clients for, each a separate host that no client's policy
  # names yet.
  @requests [
    %{
      host: "api.zentrevo-works.example",
      note:
        "The harness now loads its skills and workflows from our API. Allow the host so its agents can reach it."
    },
    %{
      host: "telemetry.zentrevo-works.example",
      note:
        "We would like the harness to report its agents' tool timings to us, so we can see where runs slow down."
    },
    %{
      host: "models.zentrevo-works.example",
      note:
        "The harness's code review agent moves to a model we host ourselves. Allow its host before the switch next month."
    }
  ]
  @decline_reasons [
    "Our security review approves every new host first; ask again after it meets.",
    "We do not use the harness's skills from your API.",
    nil
  ]

  # The after-steps' subjects.
  @narrowed_organisation "Marrowick & Pend"
  @offered_to_operator "Quistral Studio"
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

    for feature <- [:managed_organisations, :security], not Apiary.Features.on?(feature) do
      Mix.raise("the instance does not have #{feature}: run it with QORY_FEATURES=all")
    end

    clients = Keyword.get(opts, :clients, length(@clients))

    if clients not in 0..length(@clients),
      do: Mix.raise("--clients is from 0 to #{length(@clients)}")

    with_settings(fn ->
      world = world(owner!(opts[:owner]), clients)

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

  defp world(owner, clients) do
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
    world = Map.merge(world, %{organisations: organisations, operator: operator})
    Map.put(world, :clients, clients!(world, clients))
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

  ## Clients

  # The first `count` clients, every sixth of them without its first person yet.
  defp clients!(world, count) do
    clients =
      @clients
      |> Enum.take(count)
      |> Enum.with_index()
      |> Enum.map(fn {name, index} -> client!(world, name, index, rem(index, 6) != 5) end)

    joined = Enum.count(clients, & &1.person)
    first = if operator_owns?(), do: "an admin", else: "an owner"

    Mix.shell().info(
      "#{length(clients)} clients of #{world.operator.organisation.slug}, #{joined} with #{first}"
    )

    clients
  end

  # Whether the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`): a
  # client's first person is then its admin, and nobody in it is an owner. Each client
  # invites its first person as its admin, and the clients with an admin get their
  # workspaces, are narrowed and suspended as those with an owner are otherwise. Their
  # workspaces get no runs: `mix apiary.demo.history` fills a workspace in its first owner's
  # name, and such a client has none. The operator sends no policy requests, as
  # `ApiaryPro.Access` answers them not found then.
  defp operator_owns?, do: ApiaryPro.Flags.operator_infrastructure?()

  defp client!(world, name, index, accept?) do
    operator = world.operator.organisation
    email = client_owner_email(name, index)

    client =
      case find_client(operator, name) do
        %Organisation{} = client -> client
        nil -> create_client!(world, name, email, accept?)
      end

    owner = first_at(client, :owner)
    # Who joined the client first: its owner, or its admin while the operator owns it.
    person = owner || if(operator_owns?(), do: first_at(client, :admin))

    workspaces =
      if person do
        extras = for k <- 0..(extras(index) - 1)//1, do: client_workspace(index, k)
        Enum.map(["Main" | extras], &workspace!(client, &1))
      else
        # A client nobody has joined has no workspace: its first person makes the first.
        []
      end

    %{organisation: client, owner: owner, person: person, workspaces: workspaces, index: index}
  end

  defp create_client!(world, name, email, accept?) do
    scope = scope!(world.owner, world.operator.organisation)

    case capture(&Operators.create_client(scope, %{"name" => name, "email" => email}, &1)) do
      {{:ok, %{organisation: client, sent: {:ok, _invitation}}}, token} when is_binary(token) ->
        if accept?,
          do: accept!(user!(email), token, "the first invitation to #{name}")

        client

      {refused, _token} ->
        Mix.raise("the client #{name} was not created: #{inspect(refused)}")
    end
  end

  # How many workspaces a client has besides Main: none, one or two, one in average.
  defp extras(index), do: Enum.at([0, 1, 2, 1], rem(index, 4))

  defp client_workspace(index, k),
    do: Enum.at(@client_workspaces, rem(index + k, length(@client_workspaces)))

  defp client_owner_email(name, index) do
    first = Enum.at(@first_names, rem(index, length(@first_names)))
    last = Enum.at(@last_names, rem(index * 7 + 3, length(@last_names)))
    "#{first}.#{last}@#{Slug.from_name(name, "client")}.example"
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

  defp find_client(%Organisation{id: operator_id}, name) do
    Repo.one(
      from o in Organisation,
        join: t in Tenant,
        on: t.organisation_id == o.id,
        where: t.operator_id == ^operator_id and o.name == ^name,
        where: is_nil(o.deletion_marked_at),
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

    case Enum.count(world.clients, &(&1.person && !&1.owner)) do
      0 ->
        :ok

      n ->
        Mix.shell().info("#{n} clients have an admin and no owner: no runs in their workspaces")
    end

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

    clients =
      for %{owner: %User{}} = client <- world.clients,
          {workspace, j} <- Enum.with_index(client.workspaces) do
        key = {client.organisation.name, workspace.name}

        history = {
          30 + :erlang.phash2({key, :runs}, 171),
          5 + :erlang.phash2({key, :repositories}, 11),
          30 + :erlang.phash2({key, :days}, 31)
        }

        {client.organisation, workspace, history, 1_000 + 10 * client.index + j}
      end

    home ++ organisations ++ clients
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
    policy_requests(world)
    offer(world)
    arbitration(world)
    suspend_client(world)
  end

  defp grants(world) do
    organisation = Map.fetch!(world.organisations, @narrowed_organisation).organisation

    world.instance_scope
    |> Grants.set_organisation(organisation.id, [:observability])
    |> ok!("#{@narrowed_organisation} was not narrowed")

    operator_scope = scope!(world.owner, world.operator.organisation)

    narrowed_clients = narrowed_clients(world)

    for client <- narrowed_clients do
      operator_scope
      |> Grants.set_client(client.organisation.id, [:observability])
      |> ok!("#{client.organisation.name} was not narrowed")
    end

    Mix.shell().info(
      "Narrowed to observability: #{@narrowed_organisation} and #{length(narrowed_clients)} clients"
    )
  end

  # Three clients with their first person, spread across the list, granted observability
  # alone.
  defp narrowed_clients(world) do
    world.clients |> Enum.filter(& &1.person) |> Enum.take_every(14) |> Enum.take(3)
  end

  # None while the operator owns its clients: `ApiaryPro.Access` answers the policy
  # requests' actions not found then.
  defp policy_requests(world) do
    operator = world.operator.organisation

    cond do
      operator_owns?() ->
        Mix.shell().info("Policy requests: none, while the operator owns its clients")

      Repo.exists?(from r in Request, where: r.organisation_id == ^operator.id) ->
        Mix.shell().info("Policy requests: #{operator.slug} has sent some, left as they are")

      true ->
        requests!(world, operator)
    end
  end

  defp requests!(world, operator) do
    scope = scope!(world.owner, operator)
    {:ok, recipients} = PolicyRequests.recipients(scope)

    owners =
      for %{owner: %User{} = owner} = c <- world.clients,
          into: %{},
          do: {c.organisation.id, owner}

    eligible = Enum.filter(recipients, &Map.has_key?(owners, &1.id))
    send_requests(scope, eligible, owners)
  end

  defp send_requests(_scope, [], _owners),
    do: Mix.shell().info("Policy requests: no client with an owner receives one")

  defp send_requests(scope, eligible, owners) do
    [first, second, third] = @requests
    count = length(eligible)

    # The first to most of them: some accept it, some decline it, the rest have not
    # answered yet.
    to = Enum.take(eligible, div(count * 3 + 4, 5))
    request = send_request!(scope, first, to)
    {accepting, rest} = Enum.split(to, div(length(to) * 2 + 4, 5))
    {declining, _pending} = Enum.split(rest, div(length(to) + 4, 5))
    for client <- accepting, do: answer!(request, client, owners, :accept)

    for {client, reason} <- Enum.zip(declining, Stream.cycle(@decline_reasons)),
        do: answer!(request, client, owners, {:decline, reason})

    # The second to the others: a few accept it before the operator withdraws it.
    to = Enum.take(eligible, -div(count * 2 + 4, 5))
    withdrawn = send_request!(scope, second, to)

    for client <- Enum.take(to, div(length(to) + 2, 3)),
        do: answer!(withdrawn, client, owners, :accept)

    ok!(PolicyRequests.withdraw(scope, withdrawn.id), "the second request was not withdrawn")

    # The third to every other client, unanswered.
    send_request!(scope, third, Enum.take_every(eligible, 2))

    Mix.shell().info(
      "Policy requests: 3 sent; #{length(accepting)} accepted and #{length(declining)} declined the first, the second withdrawn"
    )
  end

  defp send_request!(scope, spec, clients) do
    changes = %{
      "rules" => [%{"change" => "rule_added", "action" => "allow", "host" => spec.host}]
    }

    scope
    |> PolicyRequests.send_request(%{
      "changes" => changes,
      "note" => spec.note,
      "clients" => Enum.map(clients, & &1.id)
    })
    |> ok!("the request for #{spec.host} was not sent")
  end

  # The client's owner answers, as its policy's writer: accepted in every workspace whose
  # policy they may write, or declined.
  defp answer!(request, client, owners, how) do
    scope = scope!(Map.fetch!(owners, client.id), client)
    answer = Repo.get_by!(Answer, request_id: request.id, organisation_id: client.id)

    case how do
      :accept ->
        ids = scope |> PolicyRequests.answerable_workspaces() |> Enum.map(& &1.id)

        scope
        |> PolicyRequests.accept(answer.id, ids)
        |> ok!("#{client.name} did not accept")

      {:decline, reason} ->
        scope
        |> PolicyRequests.decline(answer.id, reason)
        |> ok!("#{client.name} did not decline")
    end
  end

  # Quistral Studio offered to the operator, and not accepted, only where the instance
  # shows offers (`ApiaryPro.Flags.transfers?/0`).
  defp offer(world) do
    if ApiaryPro.Flags.transfers?(), do: make_offer(world), else: :ok
  end

  defp make_offer(world) do
    organisation = Map.fetch!(world.organisations, @offered_to_operator).organisation
    operator = world.operator.organisation

    case world.owner
         |> scope!(organisation)
         |> Transfers.offer_to_operator(operator.slug) do
      {:ok, _transfer} ->
        Mix.shell().info("#{@offered_to_operator} offered to #{operator.name}")

      {:error, reason} when reason in [:pending, :client] ->
        Mix.shell().info("#{@offered_to_operator}: offered already, left as it is")

      refused ->
        Mix.raise("#{@offered_to_operator} was not offered: #{inspect(refused)}")
    end
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

  defp suspend_client(world) do
    narrowed = MapSet.new(narrowed_clients(world), & &1.organisation.id)

    case world.clients
         |> Enum.filter(&(&1.person && not MapSet.member?(narrowed, &1.organisation.id)))
         |> List.last() do
      nil ->
        :ok

      %{organisation: client} ->
        world.instance_scope
        |> Suspensions.suspend_organisation(client.id)
        |> ok!("#{client.name} was not suspended")

        Mix.shell().info("#{client.name} suspended")
    end
  end

  ## What there is now

  defp summary(world) do
    tenants = Repo.all(from t in Tenant, select: {t.kind, t.operator_id})
    count = &Repo.aggregate(&1, :count)
    [[size]] = Repo.query!("SELECT pg_size_pretty(pg_database_size(current_database()))").rows

    held =
      Repo.aggregate(from(m in Membership, where: m.user_id == ^world.owner.id), :count)

    Mix.shell().info("""

    Organisations  #{length(tenants)}: #{Enum.count(tenants, &match?({:organisation, nil}, &1))} organisations, \
    #{Enum.count(tenants, &match?({:operator, _}, &1))} operators, \
    #{Enum.count(tenants, fn {_kind, operator} -> operator != nil end)} clients
    Workspaces     #{count.(Workspace)}
    People         #{count.(User)}, in #{count.(Membership)} memberships; #{world.owner.email} in #{held}
    Runs           #{count.(Run)}, #{count.(Apiary.Runs.Event)} events
    Audit entries  #{count.(Apiary.Audit.Entry)}
    Database       #{size}

    #{ApiaryWeb.Endpoint.url()}/#{world.instance.slug}/#{world.home.slug}/runs\
    """)
  end
end
