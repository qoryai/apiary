defmodule Apiary.Artifacts.Type do
  # An artifact type: what a version of an artifact must be, and how a page shows it.
  #
  # A type is standard, one of the eleven Qory Apiary ships (`standard/0`), or custom, a row
  # of a workspace's `artifact_types`. Both are this struct; `standard` is true for the
  # first, and a standard type has no row, so no id, public id, organisation or
  # workspace. `view` is the dedicated view of a standard structured type (`:questions`,
  # `:verdict` or `:change`), nil for every other type. A `proposal` is a document: one
  # Markdown file of up to 256 KiB, PNG, JPEG, GIF, WebP or SVG images beside it, and at
  # most one `sources.json`, up to 10 files and 5 MiB together
  # (`Apiary.Artifacts.Format`). A `mockup` is pictures, or, pushed by a run with a
  # `screens.json`, HTML pages of its screens (`Apiary.Artifacts.Mockup`). A
  # `questions` document holds every question of a work item and its answers, each
  # question with a context of up to 20,000 characters, so it takes up to 1 MiB. A
  # `review-comments` document holds every review comment of a work item, on a version
  # of an artifact such as the proposal, with its replies, up to 1 MiB. A workspace can
  # hide a standard type unless it is always on (`always_on/0`); `shown` is whether the
  # workspace shows the type, as `Apiary.Artifacts.all_types/1` sets it.
  #
  # `name` is lowercase letters and digits in groups joined by single hyphens, 1 to 64
  # bytes; a custom type's name is none of the standard names. `base_view` is one of
  # `base_views/0`. `size_limit` is the most bytes of all files of one version, and
  # `max_files` the most files of one version; a structured type has exactly one file.
  # `json_schema` is the JSON Schema a structured type's file is validated against: a
  # custom type's in its row, a standard type's under `priv/schemas/artifacts/`
  # (`schema_path`).
  #
  # The name and the base view of a custom type are fixed once it is made, since the
  # artifacts of its name were checked against its base view; its size limit, its most
  # files and its schema may change. The database checks the name's rule, the base views,
  # the bounds of the limits and that a structured type alone has a schema; the clash
  # with a standard name, and the checks of the schema, the application makes
  # (`Apiary.Artifacts.CustomSchema`).
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @typedoc "An artifact type, standard or custom."
  @type t :: %__MODULE__{}

  @typedoc """
  How a page shows a type's files, and what its files must be. `:mockup` is no type's
  base view: it is the view of a version of `mockup` that a run pushes with a
  `screens.json`, its pages (`Apiary.Artifacts.Mockup`), while the type itself is an
  image type, as every other version of it is pictures.
  """
  @type base_view :: :document | :image | :video | :file | :structured | :mockup

  @prefix "at"
  @base_views [:document, :image, :video, :file, :structured]
  @name ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @max_name 64
  @max_files 20
  @max_size 2_147_483_648

  @mib 1_048_576

  # The defaults of a custom type, by base view: its size limit, and the most it may be.
  @size_limits %{
    document: {@mib, 10 * @mib},
    image: {10 * @mib, 50 * @mib},
    video: {200 * @mib, @max_size},
    file: {50 * @mib, 1024 * @mib},
    structured: {@mib, @mib}
  }

  # The standard types: name, base view, size limit, most files, and the dedicated view.
  @standard [
    {"acceptance-criteria", :document, @mib, 1, nil},
    {"explainer", :document, @mib, 1, nil},
    {"decision-record", :document, @mib, 1, nil},
    {"mockup", :image, 10 * @mib, 10, nil},
    {"screenshot", :image, 10 * @mib, 10, nil},
    {"demo-video", :video, 200 * @mib, 5, nil},
    {"change", :structured, 64 * 1024, 1, :change},
    {"proposal", :document, 5 * @mib, 10, nil},
    {"questions", :structured, @mib, 1, :questions},
    {"review-comments", :structured, @mib, 1, nil},
    {"verdict", :structured, 64 * 1024, 1, :verdict}
  ]

  # The standard types no workspace can hide: Core's stage runner and Explore write and
  # read them by name (`Apiary.Stages`, `Apiary.Explore`), so a stage's run needs them in
  # every workspace.
  @always_on ~w(proposal questions review-comments verdict)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "artifact_types" do
    field :public_id, :string
    field :name, :string
    field :base_view, Ecto.Enum, values: @base_views
    field :size_limit, :integer
    field :max_files, :integer
    field :json_schema, :map
    field :standard, :boolean, virtual: true, default: false
    field :view, :any, virtual: true
    field :schema_path, {:array, :string}, virtual: true
    field :shown, :boolean, virtual: true, default: true

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  # prefix/0 is the prefix of a custom type's public id, `at`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # base_views/0 is the five base views, in the order a form lists them.
  @doc false
  @spec base_views() :: [base_view]
  def base_views, do: @base_views

  # standard/0 is the standard types, in the order a page lists them.
  @doc false
  @spec standard() :: [t]
  def standard do
    for {name, base_view, size_limit, max_files, view} <- @standard do
      %__MODULE__{
        name: name,
        base_view: base_view,
        size_limit: size_limit,
        max_files: max_files,
        standard: true,
        view: view,
        schema_path: if(base_view == :structured, do: schema_path(name))
      }
    end
  end

  # standard_names/0 is the names of the standard types.
  @doc false
  @spec standard_names() :: [String.t()]
  def standard_names, do: for({name, _base_view, _size, _files, _view} <- @standard, do: name)

  # always_on/0 is the names of the standard types no workspace can hide.
  @doc false
  @spec always_on() :: [String.t()]
  def always_on, do: @always_on

  defp schema_path(name), do: ["schemas", "artifacts", name <> ".schema.json"]

  # name?/1 is whether `name` follows the rule of a type's name, which an artifact's name
  # follows too: lowercase letters and digits in groups joined by single hyphens, 1 to 64
  # bytes.
  @doc false
  @spec name?(term) :: boolean
  def name?(name) when is_binary(name),
    do: byte_size(name) <= @max_name and Regex.match?(@name, name)

  def name?(_name), do: false

  # default_size_limit/1 and max_size_limit/1 are the size limit a custom type of
  # `base_view` gets when the form sets none, and the most it may have.
  @doc false
  @spec default_size_limit(base_view) :: pos_integer
  def default_size_limit(base_view), do: elem(Map.fetch!(@size_limits, base_view), 0)

  @doc false
  @spec max_size_limit(base_view) :: pos_integer
  def max_size_limit(base_view), do: elem(Map.fetch!(@size_limits, base_view), 1)

  # max_files_limit/0 is the most files a custom type's version may be allowed.
  @doc false
  @spec max_files_limit() :: pos_integer
  def max_files_limit, do: @max_files

  # create_changeset/2 is the changeset of a new custom type: name and base view, with a
  # size limit and a most files that default to the base view's (`default_size_limit/1`,
  # and 1), and a JSON Schema for a structured type alone. The checks of the schema are
  # the caller's (`Apiary.Artifacts.CustomSchema`). The organisation and the workspace
  # are the caller's to put.
  @doc false
  @spec create_changeset(t, map) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = type, attrs) do
    type
    |> cast(attrs, [:name, :base_view, :size_limit, :max_files, :json_schema])
    |> validate_required([:name, :base_view])
    |> validate_change(:name, fn :name, name ->
      cond do
        not name?(name) -> [name: {"has a form a type's name does not have", validation: :format}]
        name in standard_names() -> [name: {"is a standard type's name", validation: :standard}]
        true -> []
      end
    end)
    |> defaults()
    |> limits()
    |> put_change(:public_id, Apiary.PublicId.generate(@prefix))
    |> with_constraints()
  end

  # update_changeset/2 changes a custom type's size limit, most files and, for a
  # structured type, JSON Schema; its name and base view stay.
  @doc false
  @spec update_changeset(t, map) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{standard: false} = type, attrs) do
    type
    |> cast(attrs, [:size_limit, :max_files, :json_schema])
    |> limits()
    |> with_constraints()
  end

  defp defaults(changeset) do
    case get_field(changeset, :base_view) do
      nil ->
        changeset

      base_view ->
        changeset
        |> put_default(:size_limit, default_size_limit(base_view))
        |> put_default(:max_files, 1)
    end
  end

  defp put_default(changeset, field, value) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, value),
      else: changeset
  end

  defp limits(changeset) do
    case get_field(changeset, :base_view) do
      nil ->
        changeset

      base_view ->
        most_files = if base_view == :structured, do: 1, else: @max_files

        changeset
        |> validate_required([:size_limit, :max_files])
        |> validate_number(:size_limit,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: max_size_limit(base_view)
        )
        |> validate_number(:max_files,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: most_files
        )
        |> schema_for(base_view)
    end
  end

  defp schema_for(changeset, :structured), do: validate_required(changeset, [:json_schema])

  defp schema_for(changeset, _base_view) do
    if get_field(changeset, :json_schema),
      do:
        add_error(changeset, :json_schema, "is for a structured type only",
          validation: :base_view
        ),
      else: changeset
  end

  defp with_constraints(changeset) do
    changeset
    |> unique_constraint(:name, name: :artifact_types_workspace_id_name_index)
    |> unique_constraint(:public_id, name: :artifact_types_public_id_index)
    |> check_constraint(:name, name: :artifact_types_name_check)
    |> check_constraint(:size_limit, name: :artifact_types_size_limit_check)
    |> check_constraint(:max_files, name: :artifact_types_max_files_check)
    |> check_constraint(:json_schema, name: :artifact_types_json_schema_check)
  end
end
