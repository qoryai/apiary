defmodule Apiary.Policy.ComposedConfiguration do
  @moduledoc """
  A run configuration composed for a run: the document a run is given in place of its
  workspace's stored one (`Apiary.Policy.RunConfiguration`), or of none, when it needs
  another. Immutable, like the configuration it is composed from.

  `shape/4` decides, for the run configuration in force (its bytes, or nil where the
  workspace serves none), the image a run is given (`image`, nil for none), whether the
  run is a prebuild, and whether the image is already fixed, as it is for every answer
  after a run's attach (`fixed?`):

    * a document whose `security_policy` names an `image`, for a prebuild, is composed
      with that member left out and nothing else changed, so a prebuild always builds on
      the pool's default image;
    * a document whose `security_policy` names an `image`, for a run whose image is fixed
      (its reloads), is composed with that member left out and the run's image at the top
      level: the run keeps the image it started in, takes the rest of the policy in force,
      and the policy's image applies from the next attach (V-837);
    * a document whose `security_policy` names an `image`, for any other run, is served
      as it is, with no top-level `image`: the run starts in the image the policy names,
      and the run configuration never names a second one beside it;
    * with an `image`, the document is `{"version":1,"image":…}`, or, beside a document,
      `{"version":1,"image":…,"security_policy":…}`, the document's `security_policy`
      unchanged: the `image` beside it, never inside it;
    * else the document is served as it is, the same bytes and digest as any run's.

  A composed document's bytes are canonical, encoded as `Apiary.Policy.Render` encodes a
  document, and its `digest` is `sha256=` and the hex of them
  (`Apiary.Policy.Render.digest/1`). `serve/6` keeps it, one row per document of a
  workspace, written once and read after (insert or read), with the run configuration it
  was composed from (`run_configuration_id`, nil for none) and the image it names. A
  repeat of an attach reads it by its digest (`fetch/2`), and the badges and lookups that
  compare a run's digest with the configuration in force read a composed digest as the
  configuration it was composed from (`policy_digests/2`). A row goes with its run
  configuration, and with its workspace.
  """
  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Policy.{Render, RunConfiguration}
  alias Apiary.Repo
  alias Apiary.Runs.Run

  @type t :: %__MODULE__{}

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
  for none), the `image` it is given (or a function that reads it, asked only when the
  image is used) and whether it is a prebuild (a boolean, or a function that reads it,
  asked only when it matters), and whether the image is fixed for the run, as after its
  attach (`fixed?`, false unless given): `:as_is`, the document as stored, or
  `{:composed, bytes, image}`, with the image the bytes name at the top level, nil for
  none. See the moduledoc.
  """
  @spec shape(binary | nil, image, prebuild, boolean) ::
          :as_is | {:composed, binary, String.t() | nil}
        when image: String.t() | nil | (-> String.t() | nil),
             prebuild: boolean | (-> boolean)
  def shape(document, image, prebuild?, fixed? \\ false) do
    if is_binary(document) and names_image?(document) do
      cond do
        value(prebuild?) -> {:composed, without_image(document), nil}
        fixed? -> kept_image(document, value(image))
        true -> :as_is
      end
    else
      case value(image) do
        image when is_binary(image) -> {:composed, compose(document, image), image}
        nil -> :as_is
      end
    end
  end

  # A run whose image is fixed, under a policy that names one: its image, beside the policy
  # without the policy's; a run that has none is given the document as it is.
  defp kept_image(document, image) when is_binary(image),
    do: {:composed, compose(without_image(document), image), image}

  defp kept_image(_document, nil), do: :as_is

  defp value(fun) when is_function(fun, 0), do: fun.()
  defp value(value), do: value

  @doc """
  The digest of what `shape/4` gives, nil where it gives the document as it is: a read,
  nothing stored.
  """
  @spec digest(binary | nil, String.t() | nil, boolean | (-> boolean), boolean) ::
          String.t() | nil
  def digest(document, image, prebuild?, fixed? \\ false) do
    case shape(document, image, prebuild?, fixed?) do
      {:composed, bytes, _image} -> Render.digest(bytes)
      :as_is -> nil
    end
  end

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
  What a run is given, as `shape/4` decides it, for the run configuration in force of the
  workspace (`configuration`, nil where it serves none): `:as_is`, or `{:ok, row}`, the
  composed document kept, made now or read when it was made before. Inside or outside a
  transaction: a second writer of the same document reads the first's row.
  """
  @spec serve(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          RunConfiguration.t() | nil,
          String.t() | nil | (-> String.t() | nil),
          boolean | (-> boolean),
          boolean
        ) :: :as_is | {:ok, t}
  def serve(organisation_id, workspace_id, configuration, image, prebuild?, fixed? \\ false) do
    document = configuration && configuration.document

    case shape(document, image, prebuild?, fixed?) do
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
           conflict_target: [:organisation_id, :workspace_id, :digest],
           returning: true
         ) do
      {1, [inserted]} -> inserted
      {0, []} -> fetch(workspace_id, digest)
    end
  end

  @doc """
  Whether `run` is a run of a workspace's queue for the step `prebuild`: one read, and none
  for a run of no queue.
  """
  @spec prebuild?(Run.t()) :: boolean
  def prebuild?(%Run{dispatch_run_id: nil}), do: false

  def prebuild?(%Run{dispatch_run_id: id}),
    do:
      Repo.exists?(
        from d in DispatchRun, where: d.id == ^id and d.step == ^DispatchRun.prebuild()
      )

  @doc "The composed document of the workspace with that digest, or nil."
  @spec fetch(Ecto.UUID.t(), String.t()) :: t | nil
  def fetch(workspace_id, digest) when is_binary(workspace_id) and is_binary(digest) do
    Repo.one(
      from c in __MODULE__,
        where: c.workspace_id == ^workspace_id and c.digest == ^digest
    )
  end

  @doc """
  Each of `digests` that is a composed document's of the workspace, with the digest of the
  run configuration it was composed from, or of the document of no policy
  (`Apiary.Policy.Render.no_policy_document/0`) for one composed from none: one read. A
  digest that is no composed document's is not in the map.
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
