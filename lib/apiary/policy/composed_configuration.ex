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

  # With the `factory` feature, which the documentation leaves out, a run that must build
  # on its pool's default image is a prebuild: a run of a workspace's queue for the step
  # `prebuild` (`prebuild?/1`). No other run is one.
  #
  # Also with the `factory` feature: the members of a run (`members/1`), which every
  # document of a run of the queue is composed with, after the image is decided:
  #
  # - `variables`, the run variables Qory set for the run (`runs.registration_variables`,
  #   `Apiary.Runs.RunVariables.document/1`);
  # - with the `secrets` feature too, for a run the handover set a model provider for:
  #   `credentials`, the provider's API credential, and `model_credential`, its name
  #   (`Apiary.Runs.ProviderCredential`); and, where the document has a
  #   `security_policy`, the provider's hosts in its `egress.allow`, each added once after
  #   the entries there. An exact entry of `egress.deny` for one of those hosts is left
  #   out; a `*.` entry that covers one stays, and denies the host.
  #
  # The members come after the document's last member, in the schema's order:
  # `variables`, `credentials`, `model_credential`. A document composed with them is
  # composed for the run and kept as any other (`serve/7`), so its digest is the SHA-256
  # of the bytes the run is sent, and a document composed from no policy gains them too.
  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Policy.{Render, RunConfiguration}
  alias Apiary.Repo
  alias Apiary.Runs.{ProviderCredential, Run, RunVariables}

  @type t :: %__MODULE__{}

  @typedoc "The image a run is given, or, once fixed, what it started in (`started/1`)."
  @type image :: String.t() | {:policy, String.t()} | :none | nil

  # The unique index: one row per workspace, digest and run configuration, none counted
  # as one (`20261019000210_key_a_composed_run_configuration_by_its_policy_row`).
  @policy_index "(organisation_id, workspace_id, digest, COALESCE(run_configuration_id, '00000000-0000-0000-0000-000000000000'::uuid))"

  @version 1
  @image "image"
  @security_policy "security_policy"

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
  """
  @spec shape(binary | nil, image, prebuild, boolean, map | nil) ::
          :as_is | {:composed, binary, String.t() | nil}
        when image: image | (-> image),
             prebuild: boolean | (-> boolean)
  def shape(document, image, prebuild?, fixed? \\ false, members \\ nil) do
    case {imaged(document, image, prebuild?, fixed?), members?(members)} do
      {shaped, false} ->
        shaped

      {:as_is, true} ->
        {:composed, with_members(document, members), nil}

      {{:composed, bytes, image}, true} ->
        {:composed, with_members(bytes, members), image}
    end
  end

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
  The digest of what `shape/5` returns, nil where it returns the document as it is: a
  read, nothing stored.
  """
  @spec digest(binary | nil, image, boolean | (-> boolean), boolean, map | nil) ::
          String.t() | nil
  def digest(document, image, prebuild?, fixed? \\ false, members \\ nil) do
    case shape(document, image, prebuild?, fixed?, members) do
      {:composed, bytes, _image} -> Render.digest(bytes)
      :as_is -> nil
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
  """
  @spec serve(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          RunConfiguration.t() | nil,
          image | (-> image),
          boolean | (-> boolean),
          boolean,
          map | nil
        ) :: :as_is | {:ok, t}
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
    case members(run) do
      {:ok, members} ->
        digest(
          document,
          started(run),
          fn -> not is_nil(run) and prebuild?(run) end,
          true,
          members
        ) || digest

      {:error, :unavailable} ->
        nil
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
      members = %{variables: Map.get(run, :registration_variables), credential: credential}
      {:ok, if(members?(members), do: members)}
    end
  end

  defp members?(%{variables: variables, credential: credential}),
    do: (is_map(variables) and map_size(variables) > 0) or not is_nil(credential)

  defp members?(nil), do: false

  # `document`, or the document of no policy for nil, with the run's members after its
  # last member and the provider's hosts in its `egress`; canonical bytes.
  defp with_members(document, %{variables: variables, credential: credential}) do
    hosts = if credential, do: credential.hosts, else: []

    added =
      if(is_map(variables) and map_size(variables) > 0,
        do: [{"variables", RunVariables.document(variables)}],
        else: []
      ) ++
        if(credential,
          do: [{"credentials", [credential.entry]}, {"model_credential", credential.name}],
          else: []
        )

    names = Enum.map(added, &elem(&1, 0))

    (document || Render.no_policy_document())
    |> decode()
    |> Enum.reject(fn {name, _value} -> name in names end)
    |> Enum.map(fn
      {@security_policy, %Jason.OrderedObject{} = policy} ->
        {@security_policy, with_hosts(policy, hosts)}

      member ->
        member
    end)
    |> Kernel.++(added)
    |> encode()
  end

  # The policy with `hosts` added to its `egress.allow` after its entries, each once, and
  # an exact entry of `egress.deny` for one of them left out, the member too once empty.
  defp with_hosts(policy, []), do: policy

  defp with_hosts(%Jason.OrderedObject{values: values}, hosts) do
    values =
      Enum.map(values, fn
        {"egress", %Jason.OrderedObject{values: egress}} ->
          {"egress", Jason.OrderedObject.new(egress_with(egress, hosts))}

        member ->
          member
      end)

    Jason.OrderedObject.new(values)
  end

  defp egress_with(egress, hosts) do
    allow =
      case List.keyfind(egress, "allow", 0) do
        {"allow", allow} when is_list(allow) -> allow
        _none -> []
      end

    allow = allow ++ Enum.reject(Enum.uniq(hosts), &(&1 in allow))

    egress =
      if List.keymember?(egress, "allow", 0),
        do: List.keyreplace(egress, "allow", 0, {"allow", allow}),
        else: after_mode(egress, {"allow", allow})

    case List.keyfind(egress, "deny", 0) do
      {"deny", deny} when is_list(deny) ->
        case Enum.reject(deny, &(&1 in hosts)) do
          [] -> List.keydelete(egress, "deny", 0)
          kept -> List.keyreplace(egress, "deny", 0, {"deny", kept})
        end

      _none ->
        egress
    end
  end

  defp after_mode(egress, member) do
    case Enum.split_while(egress, fn {name, _value} -> name != "mode" end) do
      {before, [mode | rest]} -> before ++ [mode, member | rest]
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
  holds the same bytes, and whether they were composed from a run configuration or from
  none is the same for each, since a document composed from one always holds its
  `security_policy`.
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
  Each of `digests` that is a composed document's of the workspace, and never a stored
  run configuration's, with the digest of the run configuration it was composed from, or
  of the document of no policy (`Apiary.Policy.Render.no_policy_document/0`) for one
  composed from none: one read. A digest that a run configuration of the workspace was
  stored under stays that configuration's, whatever was composed to the same bytes, and
  is not in the map, nor is a digest that is no composed document's.

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
            select: {c.digest, c.run_configuration_id, r.digest}
        )
        |> Map.new(fn
          {digest, nil, _none} -> {digest, no_policy}
          {digest, _id, policy_digest} -> {digest, policy_digest}
        end)
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
