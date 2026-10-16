defmodule ApiaryWeb.NodeComponents do
  @moduledoc """
  What the Nodes list and a node's page say alike (`docs/ui.md`, Nodes): a node's state in
  words, from what it is doing (`Apiary.Nodes.activity/3`), and the sentence that says what
  an instance is. And what a node's page's two LiveViews share: its header
  (`node_header/1`) and its tabs (`node_tabs/1`), Overview, Access key and Settings. And
  what the two places that give a person the command that connects a machine share, the
  Access key tab's command page and the workspace overview's first-run box: the command
  (`enrol_command/3`, and as the pieces a page draws, `enrol_parts/3`), and the notice
  that machines can't reach a loopback address (`unreachable_server/1`). And what a node
  that chose a gateway is told wherever it is told how to connect: the gateway its runs go
  through, at its URL (`through_gateway/1`). And what the pages say of a gateway wherever
  it lives: where its page is (`gateway_path/2`), its name, with its organisation's where
  that is not the node's (`gateway_name/2`), whether the console offers gateways at the
  organisation (`organisation_gateways?/0`), and who uses an organisation's gateway now
  (`using_words/2`).

  A node's state is never Online or Offline. A Node says "Running" while its instance
  runs; a pool says how many of its instances run, against its limit when it has one
  ("3 of 10 running", "3 running"). One that runs nothing says when an instance of it was
  last seen, or, with no instance left, when one of its keys was last used, ticking in the
  browser (`seen_at/1`), or "Never seen".

  Under the command that enrols through a gateway, both places say which flag a gateway
  whose certificate a private authority signed needs (`via_ca_line/1`).
  """
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias ApiaryWeb.People

  attr :id, :string, required: true
  attr :node, Node, required: true
  attr :activity, :map, required: true, doc: "the node's `t:Apiary.Nodes.activity/0`"
  attr :class, :any, default: nil

  @doc "node_state/1 is a node's state in words: running, last seen, or never seen."
  def node_state(assigns) do
    ~H"""
    <span id={@id} class={@class}>
      <%= cond do %>
        <% @activity.running != [] -> %>
          <span class="q-sdot q-sdot-running">
            <i aria-hidden="true"></i><span>{running_words(@node, length(@activity.running))}</span>
          </span>
        <% seen = seen_at(@activity) -> %>
          {gettext("Last seen")}
          <.relative_time id={"#{@id}-seen"} at={seen} />
        <% true -> %>
          <span class="text-faint">{gettext("Never seen")}</span>
      <% end %>
    </span>
    """
  end

  @doc """
  seen_at/1 is when a node was last seen, from its `t:Apiary.Nodes.activity/0`: its
  instance seen last, or, when no instance is left (a pool's are pruned after a day), the
  last use of one of its keys, revoked ones too; nil when neither was.
  """
  @spec seen_at(map) :: DateTime.t() | nil
  def seen_at(%{last: %{last_seen_at: at}}), do: at
  def seen_at(%{used: %DateTime{} = at}), do: at
  def seen_at(_activity), do: nil

  @doc """
  running_words/2 is how many instances of `node` run, `count`, as its state says it:
  "Running" for a Node, "3 of 10 running" for a pool with a limit, "3 running" for one
  without.
  """
  @spec running_words(Node.t(), non_neg_integer) :: String.t()
  def running_words(%Node{kind: :node}, _count), do: gettext("Running")

  def running_words(%Node{instance_limit: nil}, count),
    do: gettext("%{running} running", running: Format.number(count))

  def running_words(%Node{instance_limit: limit}, count),
    do:
      gettext("%{running} of %{limit} running",
        running: Format.number(count),
        limit: Format.number(limit)
      )

  @doc """
  instance_sentence/0 is what every node's page says of an instance: a claim made under
  the node's key, never an identity.
  """
  @spec instance_sentence() :: String.t()
  def instance_sentence,
    do:
      gettext(
        "An instance is what Forager, run with this node's key, reports itself as, and anyone with the key can report any instance: to cut off one machine alone, give it a separate node."
      )

  @doc """
  node_header/1 is the header of a node's page: its name, the page's `<h1>`; its public id
  beside it, and Default beside a gateway that is its workspace's default gateway; and one
  muted line, its kind, its state and who made it and when.
  """
  attr :node, Node, required: true
  attr :activity, :map, required: true, doc: "the node's `t:Apiary.Nodes.activity/0`"

  def node_header(assigns) do
    ~H"""
    <.page_header id="node-header" title={@node.name}>
      <:badge>
        <span id="node-public-id" class="q-mono text-[13px] font-normal text-muted">
          {@node.public_id}
        </span>
        <.badge :if={@node.kind == :gateway && @node.default_gateway} class="ml-2 font-normal">
          <span id="node-default">{gettext("Default")}</span>
        </.badge>
      </:badge>
      <:description>
        <span id="node-meta" class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <span id="node-kind">{kind_label(@node.kind)}</span>
          <span class="text-faint" aria-hidden="true">·</span>
          <.node_state id="node-state" node={@node} activity={@activity} />
          <span :if={@node.created_by} class="text-faint" aria-hidden="true">·</span>
          <span :if={@node.created_by} id="node-made">
            {gettext("made by %{person}, %{date}",
              person: People.email(@node.created_by),
              date: Format.day(@node.inserted_at)
            )}
          </span>
        </span>
      </:description>
    </.page_header>
    """
  end

  @doc """
  node_tabs/1 is a node's tabs: Overview, Access key, and Settings last, set apart. Overview
  and Settings are patches of `ApiaryWeb.NodeLive.Show`, Access key is
  `ApiaryWeb.NodeLive.AccessKey`'s: `view` names the LiveView the tabs are drawn in, so each
  tab of another is a navigation.
  """
  attr :node, Node, required: true
  attr :paths, :map, required: true, doc: "`overview`, `access_key` and `settings`"
  attr :current, :atom, required: true, values: [:overview, :access_key, :settings]
  attr :view, :atom, required: true, values: [:show, :access_key]

  def node_tabs(assigns) do
    ~H"""
    <.page_tabs id="node-tabs" label={kind_label(@node.kind)} current={@current}>
      <:tab
        key={:overview}
        patch={if @view == :show, do: @paths.overview}
        navigate={if @view != :show, do: @paths.overview}
        icon="hero-book-open"
      >
        {gettext("Overview")}
      </:tab>
      <:tab
        key={:access_key}
        patch={if @view == :access_key, do: @paths.access_key}
        navigate={if @view != :access_key, do: @paths.access_key}
        icon="hero-key"
      >
        {gettext("Access key")}
      </:tab>
      <:tab
        key={:settings}
        patch={if @view == :show, do: @paths.settings}
        navigate={if @view != :show, do: @paths.settings}
        icon="hero-cog-6-tooth"
        settings
      >
        {gettext("Settings")}
      </:tab>
    </.page_tabs>
    """
  end

  @typedoc """
  A piece of the enrol command (`enrol_parts/3`): `{:text, text}`, characters to show as
  they are, spaces included; or `{:placeholder, name}`, a word the person replaces before
  running the command, shown by its name.
  """
  @type enrol_part :: {:text, String.t()} | {:placeholder, String.t()}

  @typedoc "The options of `enrol_command/3` and `enrol_parts/3`."
  @type enrol_option :: {:replace, boolean} | {:via, String.t() | nil} | feature_enrol_option()

  # The option a feature the documentation does not differ by adds (`docs: false`): an
  # adapter's command. A private type, so the served docs show its name alone.
  @typep feature_enrol_option :: {:adapter, String.t() | nil}

  @doc """
  enrol_command/3 is the command that connects a machine: `qory access-key enrol`, this
  server's address and the code as the machine sends it. Only a page that shows the
  command once calls it, with the code it holds. With `replace: true`, for a node that has
  or had a key, it carries `--replace`, so that a machine already holding a key moves to
  the new one; qory enrols a machine without a key with it all the same. With `via: url`,
  for a node whose choice leads to a gateway, it carries `--via` and the gateway's URL,
  before the server's address as qory's docs write it: qory enrols through that gateway,
  which passes the request and Qory Apiary's signed answer on unchanged, and writes the
  gateway's address into the Forager file as `gateway.server.via`. Each address and the
  code go through `shell_word/1`, so a person who pastes the command runs qory with
  them and nothing else.

  It is `enrol_parts/3` joined, each placeholder written as its name.
  """
  # With `adapter: program`, it is an adapter's command instead, which the served docs do
  # not name (`feature_enrol_option`): `program access-key enrol --secret-file FILE`, this
  # server's address and the code, where FILE is the path the person chooses for the
  # adapter's secret, written as the word FILE. The program goes through `shell_word/1` as
  # the addresses do. It carries no `--replace` and no `--via`: passing either option with
  # `:adapter`, even `replace: false` or `via: nil`, raises an `ArgumentError`.
  @spec enrol_command(String.t(), String.t(), [enrol_option]) :: String.t()
  def enrol_command(server, code, opts \\ []) when is_binary(server) and is_binary(code) do
    server
    |> enrol_parts(code, opts)
    |> Enum.map_join(fn
      {:text, text} -> text
      {:placeholder, name} -> name
    end)
  end

  @doc """
  enrol_parts/3 is the command of `enrol_command/3`, with the same arguments, as the pieces
  a page draws: `{:text, text}` and `{:placeholder, name}` (`t:enrol_part/0`), which
  concatenate with nothing between them, the spaces inside the text. Text and placeholder
  alternate, so qory's command, which has no placeholder, is one piece of text:

      [{:text, "qory access-key enrol https://qory.example.com CODE"}]

  A page shows a placeholder by its name, marked as a word to replace, and copies the text
  of `enrol_command/3`. The code is shown once, so the pieces are held by the page's
  process alone, as the command is.
  """
  # With `adapter: program` (`enrol_command/3`), the path of the adapter's secret is the
  # placeholder FILE, the only placeholder:
  #
  #     [
  #       {:text, "PROGRAM access-key enrol --secret-file "},
  #       {:placeholder, "FILE"},
  #       {:text, " https://qory.example.com CODE"}
  #     ]
  @spec enrol_parts(String.t(), String.t(), [enrol_option]) :: [enrol_part]
  def enrol_parts(server, code, opts \\ []) when is_binary(server) and is_binary(code) do
    opts
    |> enrol_words(shell_word(server), shell_word(code))
    |> Enum.intersperse({:text, " "})
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.flat_map(fn
      [{:text, _} | _] = texts -> [{:text, Enum.map_join(texts, &elem(&1, 1))}]
      placeholders -> placeholders
    end)
  end

  # The command's words, each a piece: qory's enrol, or a program's with its secret file.
  defp enrol_words(opts, server, code) do
    case Keyword.get(opts, :adapter) do
      nil ->
        replace = if Keyword.get(opts, :replace, false), do: [{:text, "--replace"}], else: []

        via =
          case Keyword.get(opts, :via) do
            nil -> []
            url when is_binary(url) -> [{:text, "--via"}, {:text, shell_word(url)}]
          end

        [{:text, "qory access-key enrol"}] ++ replace ++ via ++ [{:text, server}, {:text, code}]

      program when is_binary(program) ->
        if Keyword.has_key?(opts, :replace) or Keyword.has_key?(opts, :via),
          do: raise(ArgumentError, "the :adapter command takes neither :replace nor :via")

        [
          {:text, shell_word(program)},
          {:text, "access-key enrol --secret-file"},
          {:placeholder, "FILE"},
          {:text, server},
          {:text, code}
        ]
    end
  end

  @doc """
  shell_word/1 is `value` as one word of a POSIX shell command, its characters taken
  literally: as it is when every character is a letter, a digit or one of `. _ ~ : / -`
  and it starts with no `~`, which a shell expands there; else in single quotes, each
  `'` in it written `'\\''`. A gateway's URL holds no character a shell acts on except
  `[` and `]` of an IPv6 host, which some shells read as a pattern, so such a URL is shown
  in single quotes. A plain URL and an enrolment code are unchanged.
  """
  @spec shell_word(String.t()) :: String.t()
  def shell_word(value) when is_binary(value) do
    if value =~ ~r{\A[A-Za-z0-9._:/-][A-Za-z0-9._~:/-]*\z},
      do: value,
      else: "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  @doc """
  via_ca_line/1 is the line under the enrol command of a node whose choice leads to
  `gateway`: that a gateway whose certificate a private certificate authority signed
  needs `--via-ca-file` and that authority's PEM file, which Qory Apiary does not know.
  Nothing without a gateway.
  """
  attr :id, :string, required: true
  attr :gateway, :any, required: true, doc: "the gateway the command goes through, or nil"

  def via_ca_line(assigns) do
    ~H"""
    <p :if={@gateway} id={@id} class="text-[13px]/5 text-muted">
      <.rich text={
        rich_gettext(
          "If %{gateway}'s certificate is signed by a private certificate authority, add %{flag} and that authority's PEM file.",
          gateway: @gateway.name,
          flag: {:m, "--via-ca-file"}
        )
      } />
    </p>
    """
  end

  @doc """
  unreachable_server/1 is the notice a command's page shows when the server's address,
  which the command carries, is a loopback one (`loopback?/1`): no other machine reaches
  it, and `PUBLIC_URL` sets the one they use. Nothing where the address is any other.
  """
  attr :id, :string, required: true
  attr :url, :string, required: true, doc: "the server's address, as the command carries it"

  def unreachable_server(assigns) do
    ~H"""
    <div :if={loopback?(@url)} id={@id}>
      <.notice kind={:warning}>
        <strong>{gettext("Machines can't reach this address.")}</strong>
        {gettext(
          "%{url} works only on the computer Qory Apiary runs on. Set PUBLIC_URL to the address machines use, and the command will carry it.",
          url: @url
        )}
      </.notice>
    </div>
    """
  end

  @doc """
  loopback?/1 is whether `url`'s host is one only the computer it names reaches:
  `localhost`, a name under `.localhost`, or a loopback address, IPv4 (`127.0.0.0/8`), IPv6
  (`::1`) or IPv4 mapped into IPv6.
  """
  @spec loopback?(String.t()) :: boolean
  def loopback?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host = host |> String.downcase() |> String.trim_trailing(".")
        host == "localhost" or String.ends_with?(host, ".localhost") or loopback_ip?(host)

      _no_host ->
        false
    end
  end

  defp loopback_ip?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, high, _low}} -> Bitwise.bsr(high, 8) == 127
      _other -> false
    end
  end

  @doc """
  through_gateway/1 is what a node's enrol instructions say of its choice of gateway
  (`Apiary.Gateways.chosen/1`), as the choice leads now: that its runs go through that
  gateway, named with its URL, and, while the gateway holds no active access key, that it
  isn't connected; for a node on Default gateway while no gateway is the default, only
  that. The enrol command and the Forager file point at Qory Apiary through that gateway:
  the command carries `--via` and its URL (`enrol_command/3`), the Forager file a `via`
  line (`Apiary.AccessKeys.via_lines/1`). Nothing for a node that goes direct, a gateway,
  or a node whose named gateway is gone.
  """
  attr :id, :string, required: true
  attr :node, Node, required: true
  attr :gateway, :any, required: true, doc: "the gateway the node's runs go through, or nil"
  attr :connected, :boolean, required: true, doc: "whether the gateway holds an active key"

  attr :path, :string,
    default: nil,
    doc:
      "the page of a gateway of another organisation, where the reader opens it (`gateway_path/2`)"

  def through_gateway(assigns) do
    assigns =
      assign(assigns,
        no_default:
          is_nil(assigns.gateway) and assigns.node.kind != :gateway and
            assigns.node.gateway_choice == :default
      )

    ~H"""
    <div :if={@gateway} id={@id}>
      <.notice kind={:info}>
        <.rich
          :if={@gateway.organisation_id == @node.organisation_id}
          text={
            rich_gettext(
              "Runs of %{name} go through the gateway %{gateway}, at %{url}.",
              name: @node.name,
              gateway: @gateway.name,
              url: {:m, @gateway.url}
            )
          }
        />
        <.rich
          :if={@gateway.organisation_id != @node.organisation_id}
          text={
            rich_gettext(
              "Runs of %{name} go through the gateway %{gateway} of %{organisation}, at %{url}.",
              name: @node.name,
              gateway: if(@path, do: {:link, @path, @gateway.name}, else: @gateway.name),
              organisation: organisation_name(@gateway),
              url: {:m, @gateway.url}
            )
          }
        />
        <span :if={!@connected} id={"#{@id}-unconnected"}>
          {gettext("%{gateway} has no active access key, so it isn't connected.",
            gateway: @gateway.name
          )}
        </span>
      </.notice>
    </div>
    <div :if={@no_default} id={@id}>
      <.notice kind={:info}>{gettext("No gateway is the default now.")}</.notice>
    </div>
    """
  end

  @doc """
  gateway_field/1 is the field of a node's or a pool's form that chooses its gateway,
  `node[gateway]`: Default gateway, offered only where `offer_default` (a default
  resolves for the workspace, or the node is on it already, which keeping asks nothing
  of); Direct; and each gateway the node may name, by name (`Apiary.Gateways.gateway_choices/1`,
  by level). Where the gateways are of more than one level, they are grouped by it: "This
  workspace", then the node's organisation, then each organisation that serves it in the
  order their defaults resolve (`Apiary.Gateways.levels/1`), each named. It shows the errors
  `Apiary.Nodes` gives `gateway_choice` and `gateway_id` once the form was sent.
  `choice_params/1` turns what it sends into those two fields.
  """
  attr :form, Phoenix.HTML.Form, required: true

  attr :gateways, :list,
    required: true,
    doc: "the gateways the node may name, by level, each with its organisation"

  attr :default, :any, required: true, doc: "the workspace's default gateway, or nil"
  attr :offer_default, :boolean, required: true
  attr :disabled, :boolean, default: false

  def gateway_field(assigns) do
    changeset = assigns.form.source
    choice = Ecto.Changeset.get_field(changeset, :gateway_choice)
    named = Ecto.Changeset.get_field(changeset, :gateway_id)
    ids = Enum.map(assigns.gateways, & &1.id)

    # A gateway the node names that is no longer among those it may name: kept as it is,
    # so that saving something else does not move the node.
    gone =
      if choice == :named and named not in ids,
        do: [{gettext("A gateway that is gone"), named || ""}],
        else: []

    options =
      if(assigns.offer_default, do: [{gettext("Default gateway"), "default"}], else: []) ++
        [{gettext("Direct"), "direct"}] ++ gateway_options(assigns.gateways) ++ gone

    errors =
      if changeset.action,
        do:
          for(
            {field, error} <- changeset.errors,
            field in [:gateway_choice, :gateway_id],
            do: ApiaryWeb.CoreComponents.translate_error(error)
          ),
        else: []

    assigns =
      assign(assigns,
        options: options,
        value: if(choice == :named, do: named || "", else: to_string(choice)),
        errors: errors,
        name: assigns.form[:gateway].name,
        input_id: assigns.form[:gateway].id
      )

    ~H"""
    <.input
      id={@input_id}
      name={@name}
      type="select"
      label={gettext("Gateway")}
      value={@value}
      options={@options}
      errors={@errors}
      hint={@default && default_hint(@default)}
      disabled={@disabled}
    />
    """
  end

  # The gateways a node may name, as the select offers them: by name, in one list while
  # they are all of one level, else in a group a level.
  defp gateway_options(gateways) do
    case Enum.chunk_by(gateways, &level_key/1) do
      [] ->
        []

      [one] ->
        Enum.map(one, &{&1.name, &1.id})

      levels ->
        Enum.map(levels, fn [first | _] = level ->
          {level_label(first), Enum.map(level, &{&1.name, &1.id})}
        end)
    end
  end

  defp level_key(%Node{workspace_id: nil, organisation_id: id}), do: {:organisation, id}
  defp level_key(%Node{workspace_id: id}), do: {:workspace, id}

  defp level_label(%Node{workspace_id: nil} = gateway), do: organisation_name(gateway)
  defp level_label(%Node{}), do: gettext("This workspace")

  defp default_hint(%Node{workspace_id: nil} = default),
    do:
      gettext(
        "On Default gateway, runs go through %{name}, the default for %{organisation}. On Direct, they go through no gateway.",
        name: default.name,
        organisation: organisation_name(default)
      )

  defp default_hint(%Node{} = default),
    do:
      gettext(
        "On Default gateway, runs go through %{name}, this workspace's default. On Direct, they go through no gateway.",
        name: default.name
      )

  @doc """
  choice_params/1 is a node's form's parameters with what `gateway_field/1` sent, `gateway`,
  turned into the fields `Apiary.Nodes` takes: `default` and `direct` as the
  `gateway_choice` they name, anything else as `named` with that `gateway_id`. Parameters
  without it are as they were.
  """
  @spec choice_params(map) :: map
  def choice_params(%{"gateway" => value} = params) when value in ["default", "direct"],
    do: params |> Map.delete("gateway") |> Map.put("gateway_choice", value)

  def choice_params(%{"gateway" => value} = params),
    do:
      params
      |> Map.delete("gateway")
      |> Map.merge(%{"gateway_choice" => "named", "gateway_id" => value})

  def choice_params(params), do: params

  # How many names or run ids a refusal to delete a gateway shows before "and N more".
  @shown 5

  @doc """
  in_use_words/3 is why a gateway was not deleted, from what
  `Apiary.Gateways.delete_blockers/1` answered: the nodes that point to it, and the runs
  going through it (`runs`, when the answer has them). Only the nodes and runs the reader
  may open are named, by name and by run id, the first #{@shown} of each, then
  "and N more", which counts the rest and those of any other workspace too. For a
  workspace's gateway, those are the ones of the scope's workspace; for an organisation's,
  `reached`, the ids of the workspaces the reader reaches (`reached_workspaces/1`), and
  the rest are counted as in workspaces they don't have access to. Nil when nothing stops
  the deletion.
  """
  @spec in_use_words(Scope.t(), map, MapSet.t() | nil) :: String.t() | nil
  def in_use_words(scope, blockers, reached \\ nil) do
    nodes = listed(scope, reached, Map.get(blockers, :nodes, []), & &1.name, :nodes)
    runs = listed(scope, reached, Map.get(blockers, :runs, []), & &1.run_id, :runs)

    cond do
      nodes && runs ->
        gettext(
          "Nodes use this gateway: %{nodes}. Runs are going through it: %{runs}. Delete it once the nodes point elsewhere and the runs end.",
          nodes: nodes,
          runs: runs
        )

      nodes ->
        gettext(
          "Nodes use this gateway: %{nodes}. Point them to another gateway or to direct, then delete it.",
          nodes: nodes
        )

      runs ->
        gettext("Runs are going through this gateway: %{runs}. Delete it once they end.",
          runs: runs
        )

      true ->
        nil
    end
  end

  # The names or ids of the rows the reader may open, the first few, then how many more,
  # those of another workspace among them, never named.
  defp listed(scope, reached, rows, name, what) do
    {here, elsewhere} = Enum.split_with(rows, &named_here?(scope, reached, &1))
    {shown, rest} = here |> Enum.map(name) |> Enum.split(@shown)
    more = length(rest) + length(elsewhere)

    cond do
      rows == [] -> nil
      shown == [] -> elsewhere_words(what, reached, more)
      more == 0 -> Enum.join(shown, ", ")
      true -> Enum.join(shown, ", ") <> " " <> more_words(more)
    end
  end

  defp named_here?(scope, nil, row),
    do: row.organisation_id == scope.organisation.id and row.workspace_id == scope.workspace.id

  defp named_here?(_scope, reached, row), do: MapSet.member?(reached, row.workspace_id)

  defp more_words(more),
    do: ngettext("and %{number} more", "and %{number} more", more, number: Format.number(more))

  defp elsewhere_words(:nodes, nil, count),
    do:
      ngettext(
        "%{number} node of another workspace",
        "%{number} nodes of other workspaces",
        count,
        number: Format.number(count)
      )

  defp elsewhere_words(:runs, nil, count),
    do:
      ngettext(
        "%{number} run of another workspace",
        "%{number} runs of other workspaces",
        count,
        number: Format.number(count)
      )

  defp elsewhere_words(:nodes, _reached, count),
    do:
      ngettext(
        "%{number} node in a workspace you don't have access to",
        "%{number} nodes in workspaces you don't have access to",
        count,
        number: Format.number(count)
      )

  defp elsewhere_words(:runs, _reached, count),
    do:
      ngettext(
        "%{number} run in a workspace you don't have access to",
        "%{number} runs in workspaces you don't have access to",
        count,
        number: Format.number(count)
      )

  @doc """
  using_words/2 says which workspaces' nodes use an organisation's gateway now, from
  `Apiary.Gateways.workspaces_using/1`: "Nodes in Acme › Main, Beta › Build and 2 more
  workspaces use it now.", naming each workspace the reader reaches (`reached`, from
  `reached_workspaces/1`) by its organisation and its name, and counting the rest; "No
  node uses it now." when there are none.
  """
  @spec using_words([%Apiary.Organisations.Workspace{}], MapSet.t()) :: String.t()
  def using_words([], _reached), do: gettext("No node uses it now.")

  def using_words(workspaces, reached) do
    {named, others} = Enum.split_with(workspaces, &MapSet.member?(reached, &1.id))

    names =
      Enum.map(
        named,
        &gettext("%{organisation} › %{workspace}",
          organisation: &1.organisation.name,
          workspace: &1.name
        )
      )

    list =
      case {names, length(others)} do
        {names, 0} ->
          Enum.join(names, ", ")

        {[], count} ->
          ngettext("%{number} workspace", "%{number} workspaces", count,
            number: Format.number(count)
          )

        {names, count} ->
          Enum.join(names, ", ") <>
            " " <>
            ngettext("and %{number} more workspace", "and %{number} more workspaces", count,
              number: Format.number(count)
            )
      end

    gettext("Nodes in %{list} use it now.", list: list)
  end

  @doc """
  reached_workspaces/1 is the ids of the workspaces the reader reaches, from the places
  the console lists for them (`Apiary.Organisations.list_places/1`, the pages'
  `memberships`): the workspaces a page may name to them.
  """
  @spec reached_workspaces([map]) :: MapSet.t()
  def reached_workspaces(places) when is_list(places),
    do: MapSet.new(for place <- places, %{id: id} <- Map.get(place, :workspaces, []), do: id)

  @doc """
  organisation_gateways?/0 says whether the console offers gateways at an organisation:
  its Gateways page, the sidebar's entry and New's, where an organisation may have more
  than one workspace (`c:Apiary.Edition.limits/0`). With one workspace an organisation's
  gateways stay at the workspace.
  """
  @spec organisation_gateways?() :: boolean
  def organisation_gateways?, do: Apiary.Edition.limits().workspaces != 1

  @doc """
  gateway_path/2 is the page of `gateway` the reader of `scope` opens: a workspace's
  gateway under the workspace's Nodes, an organisation's under its Gateways. A gateway of
  another organisation, whose organisation must be loaded, is under that organisation's
  Gateways where the reader may read it there (`node.read` at that organisation, their
  membership of it read from the database); nil where they may not.
  """
  @spec gateway_path(Scope.t(), Node.t()) :: String.t() | nil
  def gateway_path(%Scope{organisation: %{id: id} = organisation}, %Node{
        organisation_id: id,
        workspace_id: nil,
        public_id: public_id
      }),
      do: ~p"/#{organisation}/gateways/#{public_id}"

  def gateway_path(%Scope{organisation: %{id: id} = organisation, workspace: workspace}, %Node{
        organisation_id: id,
        public_id: public_id
      })
      when not is_nil(workspace),
      do: ~p"/#{organisation}/#{workspace}/nodes/#{public_id}"

  def gateway_path(
        %Scope{user: %Apiary.Accounts.User{}} = scope,
        %Node{workspace_id: nil, organisation: %Organisation{} = organisation} = gateway
      ) do
    if organisation_gateways?() and reads_gateway_at?(scope, organisation, gateway),
      do: ~p"/#{organisation}/gateways/#{gateway.public_id}"
  end

  def gateway_path(_scope, _gateway), do: nil

  # Whether the person of `scope` reads `gateway` at its organisation, another than the
  # scope's, as their membership of that organisation stands.
  defp reads_gateway_at?(scope, organisation, gateway) do
    scope
    |> Scope.in_organisation(organisation)
    |> Apiary.Access.reload()
    |> Apiary.Access.can?(:"node.read", gateway)
  end

  @doc """
  gateway_name/2 is `gateway`'s name as a node of the organisation `organisation_id`
  names it: its name alone, or "edge-1 of Acme" for a gateway of another organisation,
  whose organisation must be loaded.
  """
  @spec gateway_name(Ecto.UUID.t(), Node.t()) :: String.t()
  def gateway_name(organisation_id, %Node{organisation_id: organisation_id, name: name}),
    do: name

  def gateway_name(_organisation_id, %Node{} = gateway),
    do:
      gettext("%{gateway} of %{organisation}",
        gateway: gateway.name,
        organisation: organisation_name(gateway)
      )

  @doc """
  managed_by/3 is what a nodes' page says, to a person of `scope` who may not take
  `action`, of who manages the nodes: the edition's sentence
  (`c:ApiaryWeb.Edition.nodes_managed_by_sentence/1`), else who may take it
  (`ApiaryWeb.Access.who_may/3`, `default` in the core's words).
  """
  @spec managed_by(Scope.t(), atom, String.t()) :: String.t()
  def managed_by(%Scope{} = scope, action, default),
    do:
      ApiaryWeb.Edition.nodes_managed_by_sentence(scope.organisation) ||
        ApiaryWeb.Access.who_may(scope, action, default)

  defp organisation_name(%Node{organisation: %Organisation{name: name}}), do: name

  @doc """
  limit_refused/1 is what a node's pages say to a person of `scope` who changes the node
  but not a pool's instance limit (`node.set_limit`): the edition's words of who may
  (`ApiaryWeb.Access.who_may/3`), else "You can't change the instance limit.".
  """
  @spec limit_refused(Scope.t()) :: String.t()
  def limit_refused(scope),
    do:
      ApiaryWeb.Access.who_may(
        scope,
        :"node.set_limit",
        gettext("You can't change the instance limit.")
      )

  @doc """
  node_place/1 is where a node's page stands, from its path's parameters: `:workspace`,
  under a workspace's Nodes, or `:organisation`, under the organisation's Gateways.
  """
  @spec node_place(map) :: :workspace | :organisation
  def node_place(%{"workspace" => _workspace}), do: :workspace
  def node_place(%{}), do: :organisation

  @doc """
  find_node/3 is the node a page at `place` opens: a node, pool or gateway of the scope's
  workspace in use, or a gateway in use of the scope's organisation, where the console
  offers them (`organisation_gateways?/0`); nil for any other.
  """
  @spec find_node(Scope.t(), :workspace | :organisation, String.t()) :: Node.t() | nil
  def find_node(scope, :workspace, public_id), do: Apiary.Nodes.get_node(scope, public_id)

  def find_node(scope, :organisation, public_id) do
    if organisation_gateways?(),
      do: Apiary.Nodes.get_organisation_gateway(scope, public_id)
  end

  @doc """
  nodes_path/2 is the list a node's page at `place` belongs to: the workspace's Nodes, or
  the organisation's Gateways.
  """
  @spec nodes_path(Scope.t(), :workspace | :organisation) :: String.t()
  def nodes_path(scope, :workspace), do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes"
  def nodes_path(scope, :organisation), do: ~p"/#{scope.organisation}/gateways"

  @doc "node_base/3 is the path of the page at `place` of the node `public_id`."
  @spec node_base(Scope.t(), :workspace | :organisation, String.t()) :: String.t()
  def node_base(scope, :workspace, public_id),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{public_id}"

  def node_base(scope, :organisation, public_id),
    do: ~p"/#{scope.organisation}/gateways/#{public_id}"

  @doc "nodes_label/1 is the name of the list a node's page at `place` belongs to."
  @spec nodes_label(:workspace | :organisation) :: String.t()
  def nodes_label(:workspace), do: gettext("Nodes")
  def nodes_label(:organisation), do: gettext("Gateways")

  @doc "nodes_nav/1 is the sidebar's entry of the list a node's page at `place` belongs to."
  @spec nodes_nav(:workspace | :organisation) :: :nodes | :gateways
  def nodes_nav(:workspace), do: :nodes
  def nodes_nav(:organisation), do: :gateways

  @doc """
  reads_nodes?/2 says whether the person of `scope` still reads the nodes at `place`: the
  workspace's, or the organisation's gateways.
  """
  @spec reads_nodes?(Scope.t(), :workspace | :organisation) :: boolean
  def reads_nodes?(scope, :workspace),
    do: Apiary.Access.can?(scope, :"node.read", scope.workspace)

  def reads_nodes?(scope, :organisation),
    do: Apiary.Access.can?(scope, :"node.read", scope.organisation)

  @doc """
  hidden_now?/1 says whether the nodes are hidden from the person of `scope` as the
  database has it now (`Apiary.Access.reload/2`): an edition may hide them (the part
  `nodes`, `Apiary.Features`) while a page that acts on them is open. Such a page leaves
  (`ApiaryWeb.UserAuth.reload_scope/1`) rather than say a node or a key is gone.
  """
  @spec hidden_now?(Scope.t()) :: boolean
  def hidden_now?(scope),
    do: not Apiary.Features.visible?(Apiary.Access.reload(scope), :nodes)

  @doc """
  leave_when_hidden/2 gives a page of the nodes the gate of its acts, `acts`, the names of
  the events that change something: an act asked once the nodes are hidden from the reader
  (`hidden_now?/1`) changes and reads nothing, and the page leaves
  (`ApiaryWeb.UserAuth.reload_scope/1`), as it does once it hears of the change.
  """
  @spec leave_when_hidden(Phoenix.LiveView.Socket.t(), [String.t()]) ::
          Phoenix.LiveView.Socket.t()
  def leave_when_hidden(socket, acts) do
    Phoenix.LiveView.attach_hook(socket, :nodes_hidden, :handle_event, fn
      event, _params, socket ->
        if event in acts and hidden_now?(socket.assigns.current_scope),
          do: {:halt, ApiaryWeb.UserAuth.reload_scope(socket)},
          else: {:cont, socket}
    end)
  end

  @doc """
  no_longer_member/1 tells one whose membership no longer reaches the page's place, a
  workspace's or the organisation's, that it is gone.
  """
  @spec no_longer_member(:workspace | :organisation) :: String.t()
  def no_longer_member(:workspace), do: gettext("You are no longer a member of this workspace.")

  def no_longer_member(:organisation),
    do: gettext("You are no longer a member of this organisation.")

  @doc """
  url_hint/1 is what a gateway's URL field says under it: on New gateway (`:new`), which
  adds that the gateway's Settings change it later, and in those Settings (`:settings`).
  """
  @spec url_hint(:new | :settings) :: String.t()
  def url_hint(:new),
    do:
      gettext(
        "Where your nodes will reach the machine you run qory gateway on: https://, a host, and a port if needed. You can change it later in the gateway's Settings."
      )

  def url_hint(:settings),
    do:
      gettext(
        "Where your nodes reach the machine you run qory gateway on: https://, a host, and a port if needed."
      )

  @doc "kind_label/1 is a node's kind in a word or two: Node, Node pool, Gateway."
  @spec kind_label(Node.kind()) :: String.t()
  def kind_label(:node), do: gettext("Node")
  def kind_label(:pool), do: gettext("Node pool")
  def kind_label(:gateway), do: gettext("Gateway")
end
