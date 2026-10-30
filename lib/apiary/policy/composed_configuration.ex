defmodule Apiary.Policy.ComposedConfiguration do
  @moduledoc """
  A run configuration composed for a run: the document a run is given in place of its
  workspace's stored one (`Apiary.Policy.RunConfiguration`), or of none, when it needs
  another. Immutable, like the configuration it is composed from.

  `shape/5` decides, for the run configuration in force (its bytes, or nil where the
  workspace serves none), the image a run is given, whether the run must build on its
  pool's default image, and whether the image is already fixed, as it is for every answer after a run's attach
  (`fixed?`). Before the attach, the image is the one the run is given at the top level
  (`image`, nil for none). Once it is fixed, it is what the run started in
  (`started/1`): the image it was given at the top level, `{:policy, image}` for the
  image its policy named, `:none` for none, or nil for a run whose start was not kept.

    * a document whose `security_policy` names an `image`, for a run that must build on
      its pool's default image, is composed with that member left out and nothing else
      changed, so such a run always builds on the pool's default image;
    * for a run whose image is fixed (its reloads), the gateway takes a reload only when
      it names the image the start named at the top level, or none as the start did, and
      selects the image the run started in. So a run given an image at the top level is
      given it there again, beside the `security_policy` in force without its `image`; a
      run that started in the image its policy named is given the `security_policy` in
      force with that image as its `image`, and nothing at the top level; and a run that
      started in no image is given the `security_policy` in force without its `image`.
      A document that already selects what the run started in is served as it is: the
      run takes the rest of the policy in force at once, and a policy's new image applies
      from the next attach;
    * a document whose `security_policy` names an `image`, for any other run, is served
      as it is, with no top-level `image`: the run starts in the image the policy names,
      and the run configuration never names a second one beside it;
    * with an `image`, the document is `{"version":1,"image":…}`, or, beside a document,
      `{"version":1,"image":…,"security_policy":…}`, the document's `security_policy`
      unchanged: the `image` beside it, never inside it;
    * else the document is served as it is, the same bytes and digest as any run's.

  A composed document's bytes are canonical, encoded as `Apiary.Policy.Render` encodes a
  document, and its `digest` is `sha256=` and the hex of them
  (`Apiary.Policy.Render.digest/1`). `serve/7` keeps it, one row per document of a
  workspace and run configuration it was composed from (`run_configuration_id`, nil for
  none), written once and read after (insert or read), with the image it names: leaving
  the policy's `image` out can make two run configurations give the same bytes, and each
  row names the one it was composed from. A repeat of an attach reads it by its digest
  (`fetch/2`). Whether a run is behind is the digest it reported against the one it would
  be answered now (`run_digest/2`); the lookups that name a version read a composed
  digest as the run configuration it was composed from, never redirecting a digest a run
  configuration was stored under, and prefer the one in force (`policy_digests/2`). A row
  goes with its run configuration, and with its workspace.
  """

  # With the `factory` feature, a run that must build
  # on its pool's default image is a prebuild: a run of a workspace's queue for the step
  # `prebuild` (`prebuild?/1`). No other run is one. A prebuild of a workspace that
  # serves no run configuration is composed from the workspace's default policy, not
  # from no policy (`serve_default/6`, `Apiary.Policy.default_document/1`): its document
  # always has a `security_policy`, so the registry's members below apply to it as to a
  # prebuild of a managed workspace.
  #
  # Also with the `factory` feature: the members of a run (`members/1`), which every
  # document of a run of the queue is composed with, after the image is decided:
  #
  # - `variables`, the run variables Qory set for the run (`runs.registration_variables`,
  #   `Apiary.Runs.RunVariables.document/1`);
  # - with the `secrets` feature too, for a run its claim set a model provider for:
  #   `credentials`, the provider's API credential, and `model_credential`, its name
  #   (`Apiary.Runs.ProviderCredential`); and, where the document has a
  #   `security_policy`, the provider's hosts in its `egress.allow`, each added once after
  #   the entries there, and each exact one (`Apiary.Policy.Grammar.exact_host?/1`) in its
  #   `egress.allow_first`, with the workspace's entries, sorted, each once. The gateway
  #   allows a host of `allow_first` before it reads `deny`, so no entry of `egress.deny`,
  #   exact or `*.`, blocks such a host. More than 64 entries, the most `allow_first`
  #   takes, compose no document: the run is given no run configuration (`serve/7`), as
  #   when its provider cannot be read.
  #
  # With the `registry` feature, for a run through a gateway, whatever the other features:
  # the run's registry credential, after the model key in `credentials`; the instance's
  # host and the registry's in `egress.allow` and `egress.allow_first`, as the provider's
  # hosts are; the registry host's path rules in `egress.paths`, in place of any the
  # document has for that host (`Apiary.Registry.RunAccess`); and for the instance's
  # host, the path rule `/registry/token`, after the rules the document has for that host
  # where it has some, else alone, unless the document allowed that host before: in
  # `egress.allow_first`, or in `egress.allow` and not in `egress.deny`
  # (`Apiary.Policy.Grammar.matches?/2`). Under enforce, a gateway already denies each
  # path of that host that matches neither the credential's path nor the document's
  # rules for the host. As for a provider's hosts, an entry of `egress.deny` that
  # matches the instance's host or the registry's host does not block either host.
  # Under observe, a run reaches every path of the instance's host; the gateway sends
  # the registry credential only with requests to `/registry/token`.
  #
  # For a run whose claim recorded a work credential entry (`Apiary.Runs.RunCredentials`,
  # `work/1`): the entry `work-1`, after the registry credential in `credentials`, with
  # `purpose` `work` and the apply items filled at the claim; and, where the document has
  # a `security_policy`, the hosts of its items, all exact, in `egress.allow_first`, as the
  # provider's exact hosts are, and in `egress.allow` only when `egress.mode` is
  # `enforce`. More than 8 entries in `credentials`, the most the contract takes, compose
  # no document, as more than 64 in `allow_first` do.
  #
  # For a run of a workspace's queue whose harness walk pinned a source with a network
  # host (`Apiary.Harnesses.RunHarness`, `pins`): `stack_hosts`, the hosts the run's stack
  # proxy allows for qory's fetch of the harness sources before the first session joins
  # (`stack_hosts/1`). The hosts come from every source in `pins`, not from the walk's
  # `harness_links`, and go in no `egress` list. More than 32 hosts, the most the
  # contract takes, compose no document, as more than 64 entries in `allow_first` do. A
  # run with no walk, or whose walk pinned no such source, gains no such member.
  #
  # For a run of a workspace's queue whose harness walk hid its harness
  # (`Apiary.Harnesses.RunHarness`, `harness_hidden`): `harness_hidden`, `true`. A run with
  # no walk, or whose walk did not hide its harness, gains no such member.
  #
  # The members come after the document's last member, in the schema's order:
  # `variables`, `credentials`, `model_credential`, `stack_hosts`, `harness_hidden`. A
  # document composed with them is composed for the run and kept as any other
  # (`serve/7`), so its digest is the SHA-256 of the bytes the run is sent, and a
  # document composed from no policy gains them too.
  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Policy.{Grammar, Render, RunConfiguration}
  alias Apiary.Repo
  alias Apiary.Registry.RunAccess
  alias Apiary.Runs.{ProviderCredential, Run, RunCredentials, RunVariables}

  @type t :: %__MODULE__{}

  @typedoc "Why `shape/5` composes no document: more entries than the contract takes."
  @type compose_error ::
          {:allow_first_too_long, pos_integer}
          | {:credentials_too_many, pos_integer}
          | {:stack_hosts_too_many, pos_integer}

  @typedoc "The image a run is given, or, once fixed, what it started in (`started/1`)."
  @type image :: String.t() | {:policy, String.t()} | :none | nil

  # The unique index: one row per workspace, digest and run configuration, none counted
  # as one (`20261019000210_key_a_composed_run_configuration_by_its_policy_row`).
  @policy_index "(organisation_id, workspace_id, digest, COALESCE(run_configuration_id, '00000000-0000-0000-0000-000000000000'::uuid))"

  @version 1
  @image "image"
  @security_policy "security_policy"

  # The most entries the contract's `egress.allow_first` takes, its `credentials`, and its
  # `stack_hosts`.
  @allow_first_max 64
  @credentials_max 8
  @stack_hosts_max 32

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "composed_run_configurations" do
    field :image, :string
    field :document, :string
    field :digest, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run_configuration, RunConfiguration
  end

  @doc """
  What a run is given for the run configuration `document` in force (its bytes, or nil
  for none), the `image` it is given, or what it started in once fixed (`t:image/0`, or a
  function that reads it, asked only when the image is used) and whether the run must
  build on its pool's default image (a boolean, or a function that reads it, asked only
  when it matters), and whether the image is fixed for the run, as after its
  attach (`fixed?`, false unless given): `:as_is`, the document as stored, or
  `{:composed, bytes, image}`, with the image the bytes name at the top level, nil for
  none. See the moduledoc. `members`, nil unless given, is what else the run's document
  is composed with: its run variables, nil for none.
  `{:error, {:allow_first_too_long, count}}` when the members would give
  `egress.allow_first` more than 64 entries, `{:error, {:credentials_too_many, count}}`
  when they would give `credentials` more than 8, and `{:error, {:stack_hosts_too_many,
  count}}` when they would give `stack_hosts` more than 32.
  """
  @spec shape(binary | nil, image, prebuild, boolean, map | nil) ::
          :as_is
          | {:composed, binary, String.t() | nil}
          | {:error, compose_error}
        when image: image | (-> image),
             prebuild: boolean | (-> boolean)
  def shape(document, image, prebuild?, fixed? \\ false, members \\ nil) do
    case {imaged(document, image, prebuild?, fixed?), members?(members)} do
      {shaped, false} ->
        shaped

      {:as_is, true} ->
        document |> with_members(members) |> composed(nil)

      {{:composed, bytes, image}, true} ->
        bytes |> with_members(members) |> composed(image)
    end
  end

  defp composed({:ok, bytes}, image), do: {:composed, bytes, image}
  defp composed({:error, _reason} = error, _image), do: error

  # What `shape/5` returns for the image alone.
  defp imaged(document, image, prebuild?, fixed?) do
    if is_binary(document) and names_image?(document) do
      cond do
        value(prebuild?) -> {:composed, without_image(document), nil}
        fixed? -> kept_image(document, value(image))
        true -> :as_is
      end
    else
      case value(image) do
        image when is_binary(image) ->
          {:composed, compose(document, image), image}

        {:policy, image} when fixed? and is_binary(document) ->
          {:composed, with_policy_image(document, image), nil}

        _none ->
          :as_is
      end
    end
  end

  # A run whose image is fixed, under a policy that names one: an image given at the top
  # level stays there, beside the policy without the policy's; an image the start's policy
  # named takes the place of the policy's, the document as it is when they are the same;
  # no image leaves the policy's out. A run whose start was not kept is given the document
  # as it is.
  defp kept_image(document, image) when is_binary(image),
    do: {:composed, compose(without_image(document), image), image}

  defp kept_image(document, {:policy, image}) when is_binary(image) do
    if policy_image(document) == image,
      do: :as_is,
      else: {:composed, with_policy_image(document, image), nil}
  end

  defp kept_image(document, :none), do: {:composed, without_image(document), nil}
  defp kept_image(_document, nil), do: :as_is

  defp value(fun) when is_function(fun, 0), do: fun.()
  defp value(value), do: value

  @doc """
  The digest of what `shape/5` returns, nil where it returns the document as it is, and
  its error where it composes none: a read, nothing stored.
  """
  @spec digest(binary | nil, image, boolean | (-> boolean), boolean, map | nil) ::
          String.t() | nil | {:error, compose_error}
  def digest(document, image, prebuild?, fixed? \\ false, members \\ nil) do
    case shape(document, image, prebuild?, fixed?, members) do
      {:composed, bytes, _image} -> Render.digest(bytes)
      :as_is -> nil
      {:error, _reason} = error -> error
    end
  end

  @doc """
  What a run started in, as `shape/5` reads it once its image is fixed: the image it was
  given at the top level (`configured_image`), `{:policy, image}` for the image its
  policy named, `:none` for none; nil for a run whose start was not kept, nor given an
  image, and for nil.
  """
  @spec started(Run.t() | nil) :: String.t() | {:policy, String.t()} | :none | nil
  def started(%Run{started_image_from: "policy", started_image: image}) when is_binary(image),
    do: {:policy, image}

  def started(%Run{started_image_from: "none"}), do: :none
  def started(%Run{configured_image: image}), do: image
  def started(nil), do: nil

  @doc """
  The image the `security_policy` of the run configuration `document` names, nil for none
  and for no document.
  """
  @spec policy_image(binary | nil) :: String.t() | nil
  def policy_image(document) when is_binary(document) do
    if names_image?(document) do
      case Jason.decode!(document) do
        %{@security_policy => %{@image => image}} when is_binary(image) -> image
        _other -> nil
      end
    end
  end

  def policy_image(nil), do: nil

  @doc """
  Whether the run configuration `document` names an image in its `security_policy`.
  """
  @spec names_image?(binary) :: boolean
  def names_image?(document) when is_binary(document) do
    String.contains?(document, ~s("#{@image}")) and
      match?(%{@security_policy => %{@image => _}}, Jason.decode!(document))
  end

  @doc """
  `{"version":1,"image":…}` for no document, or the run configuration `document` with
  `image` after its `version`, its other members as they are; canonical bytes.
  """
  @spec compose(binary | nil, String.t()) :: binary
  def compose(nil, image) when is_binary(image),
    do: encode([{"version", @version}, {@image, image}])

  def compose(document, image) when is_binary(document) and is_binary(image) do
    members = decode(document)
    {version, members} = take(members, "version")
    {_image, members} = take(members, @image)
    encode([{"version", version}, {@image, image} | members])
  end

  @doc """
  The run configuration `document` with its `security_policy`'s `image` left out, every
  other member as it is; canonical bytes.
  """
  @spec without_image(binary) :: binary
  def without_image(document) when is_binary(document) do
    document
    |> decode()
    |> Enum.map(fn
      {@security_policy, %Jason.OrderedObject{values: values}} ->
        {@security_policy, Jason.OrderedObject.new(List.keydelete(values, @image, 0))}

      member ->
        member
    end)
    |> encode()
  end

  # The run configuration `document` with its `security_policy`'s `image` set to `image`:
  # in its place when the policy names one, else after the policy's other members; every
  # other member as it is; canonical bytes.
  defp with_policy_image(document, image) do
    document
    |> decode()
    |> Enum.map(fn
      {@security_policy, %Jason.OrderedObject{values: values}} ->
        values =
          if List.keymember?(values, @image, 0),
            do: List.keyreplace(values, @image, 0, {@image, image}),
            else: values ++ [{@image, image}]

        {@security_policy, Jason.OrderedObject.new(values)}

      member ->
        member
    end)
    |> encode()
  end

  defp decode(document) do
    %Jason.OrderedObject{values: values} = Jason.decode!(document, objects: :ordered_objects)
    values
  end

  defp take(members, name) do
    case List.keytake(members, name, 0) do
      {{^name, value}, rest} -> {value, rest}
      nil -> {nil, members}
    end
  end

  defp encode(members),
    do: Jason.encode!(Jason.OrderedObject.new(members), escape: :json)

  @doc """
  What a run receives, as `shape/5` composes it, for the run configuration in force of the
  workspace (`configuration`, nil where it serves none): `:as_is`, or `{:ok, row}`, the
  composed document kept, made now or read when it was made before. Inside or outside a
  transaction: a second writer of the same document reads the first's row.
  `{:error, reason}`, as `shape/5` returns it, with a line in the log, where `shape/5`
  composes none.
  """
  @spec serve(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          RunConfiguration.t() | nil,
          image | (-> image),
          boolean | (-> boolean),
          boolean,
          map | nil
        ) :: :as_is | {:ok, t} | {:error, compose_error}
  def serve(
        organisation_id,
        workspace_id,
        configuration,
        image,
        prebuild?,
        fixed? \\ false,
        members \\ nil
      ) do
    document = configuration && configuration.document

    case shape(document, image, prebuild?, fixed?, members) do
      :as_is ->
        :as_is

      {:composed, bytes, image} ->
        {:ok, kept(organisation_id, workspace_id, configuration, image, bytes)}

      {:error, {:allow_first_too_long, count}} = error ->
        Logger.error(
          "a run's run configuration was not composed: its allow_first would have " <>
            "#{count} hosts, more than the 64 the contract takes: the run is given no " <>
            "run configuration"
        )

        error

      {:error, {:credentials_too_many, count}} = error ->
        Logger.error(
          "a run's run configuration was not composed: it would have #{count} " <>
            "credentials, more than the 8 the contract takes: the run is given no " <>
            "run configuration"
        )

        error

      {:error, {:stack_hosts_too_many, count}} = error ->
        Logger.error(
          "a run's run configuration was not composed: its stack_hosts would have " <>
            "#{count} hosts, more than the 32 the contract takes: the run is given no " <>
            "run configuration"
        )

        error
    end
  end

  @doc """
  What a prebuild of a workspace that serves no run configuration receives: the
  workspace's default policy, `document` (`Apiary.Policy.default_document/1`), composed
  as `serve/7` composes a run configuration in force for a prebuild, and kept as a
  document composed from none (`run_configuration_id` nil), the default policy's bytes
  too where nothing is composed. `{:ok, row}`, or `{:error, reason}` as `serve/7`.
  """
  @spec serve_default(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          binary,
          image | (-> image),
          boolean,
          map | nil
        ) :: {:ok, t} | {:error, compose_error}
  def serve_default(organisation_id, workspace_id, document, image, fixed?, members)
      when is_binary(document) do
    case serve(
           organisation_id,
           workspace_id,
           %RunConfiguration{document: document},
           image,
           true,
           fixed?,
           members
         ) do
      :as_is -> {:ok, kept(organisation_id, workspace_id, nil, nil, document)}
      other -> other
    end
  end

  defp kept(organisation_id, workspace_id, configuration, image, bytes) do
    digest = Render.digest(bytes)

    row = %{
      id: Ecto.UUID.generate(),
      organisation_id: organisation_id,
      workspace_id: workspace_id,
      run_configuration_id: configuration && configuration.id,
      image: image,
      document: bytes,
      digest: digest,
      inserted_at: DateTime.utc_now()
    }

    case Repo.insert_all(__MODULE__, [row],
           on_conflict: :nothing,
           conflict_target: {:unsafe_fragment, @policy_index},
           returning: true
         ) do
      {1, [inserted]} -> inserted
      {0, []} -> composed_from(workspace_id, digest, row.run_configuration_id)
    end
  end

  # The row of the workspace with that digest composed from that run configuration (nil
  # for none).
  defp composed_from(workspace_id, digest, nil) do
    Repo.one!(
      from c in __MODULE__,
        where:
          c.workspace_id == ^workspace_id and c.digest == ^digest and
            is_nil(c.run_configuration_id)
    )
  end

  defp composed_from(workspace_id, digest, run_configuration_id) do
    Repo.one!(
      from c in __MODULE__,
        where:
          c.workspace_id == ^workspace_id and c.digest == ^digest and
            c.run_configuration_id == ^run_configuration_id
    )
  end

  @doc """
  The digest a run is answered on a reload under the run configuration `configuration`:
  the document composed for it as `shape/5` composes it, with what the run started in
  (`started/1`), whether it must build on its pool's default image or not, its image
  fixed; the digest `configuration` is stored under where nothing is composed. A run that
  is nil is one the caller does not know: no image, and no build on the default image.
  Nil when the run's document cannot be composed, and its reload then returns none. A
  read, nothing stored.
  """
  @spec run_digest(RunConfiguration.t(), Run.t() | nil) :: String.t() | nil
  def run_digest(%RunConfiguration{document: document, digest: digest}, run) do
    with {:ok, members} <- members(run) do
      case digest(
             document,
             started(run),
             fn -> not is_nil(run) and prebuild?(run) end,
             true,
             members
           ) do
        composed when is_binary(composed) -> composed
        nil -> digest
        {:error, _reason} -> nil
      end
    else
      {:error, :unavailable} -> nil
    end
  end

  # members/1 is what the documents of `run` are composed with beside the image (see the
  # comment after the moduledoc): `{:ok, members}`, nil for none, or
  # `{:error, :unavailable}` when its model provider cannot be read
  # (`Apiary.Runs.ProviderCredential.for_run/1`). A run that is nil has none.
  @doc false
  @spec members(Run.t() | map | nil) :: {:ok, map | nil} | {:error, :unavailable}
  def members(nil), do: {:ok, nil}

  def members(run) do
    with {:ok, credential} <- ProviderCredential.for_run(run) do
      {hidden?, pins} = walk(run)

      members = %{
        variables: Map.get(run, :registration_variables),
        credential: credential,
        registry: RunAccess.member(run),
        work: RunCredentials.work(run),
        stack_hosts: stack_hosts(pins),
        harness_hidden: hidden?
      }

      {:ok, if(members?(members), do: members)}
    end
  end

  defp members?(%{variables: variables, credential: credential} = members),
    do:
      (is_map(variables) and map_size(variables) > 0) or not is_nil(credential) or
        not is_nil(Map.get(members, :registry)) or not is_nil(Map.get(members, :work)) or
        Map.get(members, :stack_hosts, []) != [] or Map.get(members, :harness_hidden) == true

  defp members?(nil), do: false

  # The harness walk of `run`'s run of the queue: whether it hid its harness, and the
  # sources it pinned, in its order; `{false, []}` for a run of no queue, and for one with
  # no walk.
  defp walk(run) do
    case Map.get(run, :dispatch_run_id) do
      id when is_binary(id) ->
        Repo.one(
          from h in RunHarness,
            where: h.dispatch_run_id == ^id,
            select: {h.harness_hidden, h.pins}
        ) || {false, []}

      _none ->
        {false, []}
    end
  end

  # stack_hosts/1 is the hosts of the harness sources `pins` (`%{"git" => url, …}` each,
  # as a harness walk pins them), for a run configuration's `stack_hosts`: each URL's
  # host, lower-case, with no scheme, user information, port or path, each once, in the
  # order of `pins`. A source with no network host, such as a `file://` URL or a local
  # path, adds none, nor does a host that is no exact entry of the contract's host
  # grammar (`Apiary.Policy.Grammar.exact_host?/1`), such as an IPv6 address.
  @doc false
  @spec stack_hosts([map] | nil) :: [String.t()]
  def stack_hosts(pins) when is_list(pins) do
    pins
    |> Enum.flat_map(fn
      %{"git" => git} when is_binary(git) -> [source_host(git)]
      _other -> []
    end)
    |> Enum.filter(&Grammar.exact_host?/1)
    |> Enum.uniq()
  end

  def stack_hosts(nil), do: []

  @doc false
  # workspace_stack_hosts/1 is the hosts of the harness sources the workspace chooses, as
  # `stack_hosts/1` writes them for a run: the workspace's harness
  # (`Apiary.Stacks.Sources.chosen/1`) and the harness chosen for each of its targets
  # (`Apiary.Stacks.Sources.targets_chosen/1`), each `%{host:, git:, shared:}`, once.
  # `shared` is true for the harness the organisation shares with its workspaces, false for
  # a choice made in this workspace, for the workspace or for one of its targets. A run
  # adds the sources that the pins of its walk name besides. `[]` without the `factory`
  # feature, as a run of no queue has no stack hosts.
  @spec workspace_stack_hosts(Apiary.Organisations.Workspace.t()) :: [
          %{host: String.t(), git: String.t(), shared: boolean}
        ]
  def workspace_stack_hosts(%Apiary.Organisations.Workspace{} = workspace) do
    if Apiary.Features.on?(:factory) do
      %{git: git, shared: shared} = Apiary.Stacks.Sources.chosen(workspace)

      targets =
        for {_target, %{git: git}} <- Apiary.Stacks.Sources.targets_chosen(workspace),
            do: {git, false}

      for {git, shared} <- Enum.uniq_by([{git, shared} | targets], &elem(&1, 0)),
          is_binary(git),
          host <- stack_hosts([%{"git" => git}]),
          do: %{host: host, git: git, shared: shared}
    else
      []
    end
  end

  @doc false
  # source_host/1 is the lower-case host of the harness source address `git`, nil for an
  # address with none.
  @spec source_host(String.t()) :: String.t() | nil
  def source_host(git) do
    case URI.parse(git) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _none -> nil
    end
  end

  # `document`, or the document of no policy for nil, with the run's members after its
  # last member and the provider's hosts in its `egress`: `{:ok, bytes}`, canonical, or
  # `{:error, {:allow_first_too_long, count}}`, or `{:error, {:credentials_too_many,
  # count}}` for more than the 8 entries `credentials` takes, or `{:error,
  # {:stack_hosts_too_many, count}}` for more than the 32 hosts `stack_hosts` takes.
  defp with_members(document, %{variables: variables, credential: credential} = run_members) do
    registry = Map.get(run_members, :registry)
    work = Map.get(run_members, :work)
    stack_hosts = Map.get(run_members, :stack_hosts) || []

    hosts =
      if(credential, do: credential.hosts, else: []) ++ if(registry, do: registry.hosts, else: [])

    entries =
      if(credential, do: [credential.entry], else: []) ++
        if(registry, do: [registry.entry], else: []) ++
        if work, do: [work.entry], else: []

    added =
      if(is_map(variables) and map_size(variables) > 0,
        do: [{"variables", RunVariables.document(variables)}],
        else: []
      ) ++
        if(entries != [], do: [{"credentials", entries}], else: []) ++
        if(credential, do: [{"model_credential", credential.name}], else: []) ++
        if(stack_hosts != [], do: [{"stack_hosts", stack_hosts}], else: []) ++
        if Map.get(run_members, :harness_hidden) == true,
          do: [{"harness_hidden", true}],
          else: []

    names = Enum.map(added, &elem(&1, 0))

    members =
      (document || Render.no_policy_document())
      |> decode()
      |> Enum.reject(fn {name, _value} -> name in names end)

    open? = is_map(registry) and host_open?(members, registry.instance_host)

    with :ok <- credentials_fit(entries),
         :ok <- stack_hosts_fit(stack_hosts),
         {:ok, members} <- policy_with_hosts(members, hosts, if(work, do: work.hosts, else: [])),
         do: {:ok, encode(policy_with_paths(members, registry, open?) ++ added)}
  end

  defp credentials_fit(entries) when length(entries) > @credentials_max,
    do: {:error, {:credentials_too_many, length(entries)}}

  defp credentials_fit(_entries), do: :ok

  defp stack_hosts_fit(hosts) when length(hosts) > @stack_hosts_max,
    do: {:error, {:stack_hosts_too_many, length(hosts)}}

  defp stack_hosts_fit(_hosts), do: :ok

  # Whether the document's `egress` allows `host` before any host is added: in
  # `allow_first`, or in `allow` and not in `deny`.
  defp host_open?(members, host) do
    with {@security_policy, %Jason.OrderedObject{values: policy}} <-
           List.keyfind(members, @security_policy, 0),
         {"egress", %Jason.OrderedObject{values: egress}} <- List.keyfind(policy, "egress", 0) do
      list = fn name ->
        case List.keyfind(egress, name, 0) do
          {^name, entries} when is_list(entries) -> Enum.filter(entries, &is_binary/1)
          _none -> []
        end
      end

      Grammar.matches?(list.("allow_first"), host) or
        (Grammar.matches?(list.("allow"), host) and not Grammar.matches?(list.("deny"), host))
    else
      _none -> false
    end
  end

  # The members with the registry's path rules for its host in the `security_policy`'s
  # `egress.paths`, where there is an `egress`: in place of the host's entry where it has
  # one, else after the entries there (`Apiary.Registry.RunAccess`). Then the instance's
  # host's: `/registry/token` after the rules of its entry where it has one, else, unless
  # `open?`, an entry of that one rule after the entries there.
  defp policy_with_paths(members, nil, _open?), do: members

  defp policy_with_paths(
         members,
         %{registry_host: host, paths: paths, instance_host: instance},
         open?
       ) do
    with {@security_policy, %Jason.OrderedObject{values: policy}} <-
           List.keyfind(members, @security_policy, 0),
         {"egress", %Jason.OrderedObject{values: egress}} <- List.keyfind(policy, "egress", 0) do
      entries =
        case List.keyfind(egress, "paths", 0) do
          {"paths", %Jason.OrderedObject{values: entries}} -> entries
          _none -> []
        end

      entries =
        if List.keymember?(entries, host, 0),
          do: List.keyreplace(entries, host, 0, {host, paths}),
          else: entries ++ [{host, paths}]

      entries =
        case List.keyfind(entries, instance, 0) do
          {^instance, rules} when is_list(rules) ->
            List.keyreplace(
              entries,
              instance,
              0,
              {instance, Enum.uniq(rules ++ [RunAccess.token_path()])}
            )

          nil when not open? ->
            entries ++ [{instance, [RunAccess.token_path()]}]

          _open ->
            entries
        end

      egress =
        if List.keymember?(egress, "paths", 0),
          do: List.keyreplace(egress, "paths", 0, {"paths", Jason.OrderedObject.new(entries)}),
          else: egress ++ [{"paths", Jason.OrderedObject.new(entries)}]

      policy = List.keyreplace(policy, "egress", 0, {"egress", Jason.OrderedObject.new(egress)})

      List.keyreplace(
        members,
        @security_policy,
        0,
        {@security_policy, Jason.OrderedObject.new(policy)}
      )
    else
      _none -> members
    end
  end

  # The members with the provider's `hosts` in the `security_policy`'s `egress`, where
  # there is one: added to `egress.allow` after its entries, each once, and each exact one
  # to `egress.allow_first`, with the entries there, sorted, each once. The work entry's
  # `work_hosts`, all exact, go to `egress.allow_first` as well, and to `egress.allow`
  # only when the mode is `enforce`.
  defp policy_with_hosts(members, [], []), do: {:ok, members}

  defp policy_with_hosts(members, hosts, work_hosts) do
    with {@security_policy, %Jason.OrderedObject{values: policy}} <-
           List.keyfind(members, @security_policy, 0),
         {"egress", %Jason.OrderedObject{values: egress}} <- List.keyfind(policy, "egress", 0),
         {:ok, egress} <- egress_with(egress, hosts, work_hosts) do
      policy = List.keyreplace(policy, "egress", 0, {"egress", Jason.OrderedObject.new(egress)})

      {:ok,
       List.keyreplace(
         members,
         @security_policy,
         0,
         {@security_policy, Jason.OrderedObject.new(policy)}
       )}
    else
      {:error, _reason} = error -> error
      _none -> {:ok, members}
    end
  end

  defp egress_with(egress, hosts, work_hosts) do
    allow =
      case List.keyfind(egress, "allow", 0) do
        {"allow", allow} when is_list(allow) -> allow
        _none -> []
      end

    allowed =
      if List.keyfind(egress, "mode", 0) == {"mode", "enforce"},
        do: hosts ++ work_hosts,
        else: hosts

    allow = allow ++ Enum.reject(Enum.uniq(allowed), &(&1 in allow))

    egress =
      if List.keymember?(egress, "allow", 0),
        do: List.keyreplace(egress, "allow", 0, {"allow", allow}),
        else: after_member(egress, "mode", {"allow", allow})

    first =
      case List.keyfind(egress, "allow_first", 0) do
        {"allow_first", first} when is_list(first) -> first
        _none -> []
      end

    case Enum.sort(Enum.uniq(first ++ Enum.filter(hosts ++ work_hosts, &Grammar.exact_host?/1))) do
      [] ->
        {:ok, egress}

      first when length(first) > @allow_first_max ->
        {:error, {:allow_first_too_long, length(first)}}

      first ->
        if List.keymember?(egress, "allow_first", 0),
          do: {:ok, List.keyreplace(egress, "allow_first", 0, {"allow_first", first})},
          else: {:ok, after_member(egress, "allow", {"allow_first", first})}
    end
  end

  # `egress` with `member` right after its member named `name`, else first.
  defp after_member(egress, name, member) do
    case Enum.split_while(egress, fn {key, _value} -> key != name end) do
      {before, [found | rest]} -> before ++ [found, member | rest]
      {all, []} -> [member | all]
    end
  end

  # Whether `run` is a run of a workspace's queue for the step `prebuild`: one read, and
  # none for a run of no queue. Of the `factory` feature, which the documentation leaves
  # out.
  @doc false
  @spec prebuild?(Run.t()) :: boolean
  def prebuild?(%Run{dispatch_run_id: nil}), do: false

  def prebuild?(%Run{dispatch_run_id: id}),
    do:
      Repo.exists?(
        from d in DispatchRun, where: d.id == ^id and d.step == ^DispatchRun.prebuild()
      )

  @doc """
  A composed document of the workspace with that digest, or nil: every row with one digest
  holds the same bytes. The oldest is read where two have that digest, as a document
  composed from a run configuration and one composed from the workspace's default policy
  (`serve_default/6`) can.
  """
  @spec fetch(Ecto.UUID.t(), String.t()) :: t | nil
  def fetch(workspace_id, digest) when is_binary(workspace_id) and is_binary(digest) do
    Repo.one(
      from c in __MODULE__,
        where: c.workspace_id == ^workspace_id and c.digest == ^digest,
        order_by: [asc: c.inserted_at, asc: c.id],
        limit: 1
    )
  end

  @doc """
  Whether the document with that digest was composed from no run configuration in the
  workspace: what a run given an image where the workspace served none was answered at
  its attach.
  """
  @spec from_no_policy?(Ecto.UUID.t(), String.t() | nil) :: boolean
  def from_no_policy?(workspace_id, digest) when is_binary(workspace_id) and is_binary(digest) do
    Repo.exists?(
      from c in __MODULE__,
        where:
          c.workspace_id == ^workspace_id and c.digest == ^digest and
            is_nil(c.run_configuration_id)
    )
  end

  def from_no_policy?(_workspace_id, nil), do: false

  @doc """
  Whether the document with that digest was composed from the workspace's default policy
  (`serve_default/6`): composed from no run configuration, with a `security_policy`. Only
  a prebuild of a workspace that serves no run configuration is given one.
  """
  @spec default_policy?(Ecto.UUID.t(), String.t() | nil) :: boolean
  def default_policy?(workspace_id, digest) when is_binary(workspace_id) and is_binary(digest) do
    Repo.exists?(
      from c in __MODULE__,
        where:
          c.workspace_id == ^workspace_id and c.digest == ^digest and
            is_nil(c.run_configuration_id),
        where: fragment("jsonb_exists(?::jsonb, ?)", c.document, @security_policy)
    )
  end

  def default_policy?(_workspace_id, nil), do: false

  @doc """
  Each of `digests` that is a composed document's of the workspace, and never a stored
  run configuration's, with the digest of the run configuration it was composed from, or
  of the document of no policy (`Apiary.Policy.Render.no_policy_document/0`) for one
  composed from none: one read. A digest that a run configuration of the workspace was
  stored under stays that configuration's, whatever was composed to the same bytes, and
  is not in the map, nor is a digest that is no composed document's, nor one composed
  from the workspace's default policy (`serve_default/6`), which has a `security_policy`
  and is no version: it stays as it is.

  The same bytes can be composed from two run configurations, since leaving the policy's
  `image` out can make two of them alike. Such a digest names the one that is in force
  for its holder (the baseline or its target), else the newest rendered.
  """
  @spec policy_digests(Ecto.UUID.t(), [String.t() | nil]) :: %{String.t() => String.t()}
  def policy_digests(workspace_id, digests) when is_binary(workspace_id) and is_list(digests) do
    case digests |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        %{}

      digests ->
        no_policy = Render.digest(Render.no_policy_document())

        Repo.all(
          from c in __MODULE__,
            left_join: r in RunConfiguration,
            on: r.id == c.run_configuration_id,
            where: c.workspace_id == ^workspace_id and c.digest in ^digests,
            where:
              fragment(
                "NOT EXISTS (SELECT 1 FROM run_configurations s WHERE s.workspace_id = ? AND s.digest = ?)",
                c.workspace_id,
                c.digest
              ),
            order_by: [
              asc: c.digest,
              desc:
                fragment(
                  "NOT EXISTS (SELECT 1 FROM run_configurations n WHERE n.workspace_id = ? AND n.version > ? AND n.target_id IS NOT DISTINCT FROM ?)",
                  r.workspace_id,
                  r.version,
                  r.target_id
                ),
              desc_nulls_last: r.rendered_at
            ],
            distinct: c.digest,
            select:
              {c.digest, c.run_configuration_id, r.digest,
               fragment("jsonb_exists(?::jsonb, ?)", c.document, @security_policy)}
        )
        |> Enum.flat_map(fn
          {_digest, nil, _none, true} -> []
          {digest, nil, _none, false} -> [{digest, no_policy}]
          {digest, _id, policy_digest, _policy?} -> [{digest, policy_digest}]
        end)
        |> Map.new()
    end
  end

  @doc """
  `digest` as the configuration it was composed from (`policy_digests/2`), or as it is
  when it is no composed document's of the workspace; nil for nil.
  """
  @spec policy_digest(Ecto.UUID.t(), String.t() | nil) :: String.t() | nil
  def policy_digest(_workspace_id, nil), do: nil

  def policy_digest(workspace_id, digest) when is_binary(digest),
    do: Map.get(policy_digests(workspace_id, [digest]), digest, digest)
end
