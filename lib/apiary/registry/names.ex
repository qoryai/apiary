defmodule Apiary.Registry.Names do
  @moduledoc false

  # The image names a registry token may grant, with the `registry` feature, which the
  # documentation leaves out. Every name is one of:
  #
  #   * `<instance>/<org>/targets/<target>`, a target's image;
  #   * `<instance>/<org>/environments/<key>`, an environment image of the organisation;
  #   * `shared/<name>`, an image every organisation pulls;
  #   * `upstream/<host>/<path>`, the registry's copy of a public image, for one of the 4
  #     hosts of `upstream_hosts/0`.
  #
  # `<instance>` is the instance's registry name, 16 random lower-case hex digits made
  # once (`Apiary.InstanceConfig.registry_instance/0`), so it is one name segment and
  # never `shared` or `upstream`. `<org>` is the first 16 hex digits of the SHA-256 of the
  # organisation's id, in its text form; `<target>` the same of the target's public id
  # (`tg_…`). `<key>` is the first 16 hex digits of the SHA-256 of the JSON array
  # `["qory registry environment key v1", <organisation id>, <environment_ref>, <machine
  # kind>, [<egress hosts>], [<credential hosts>]]`, each host list sorted and each host
  # once, encoded by Jason with no spaces (`environment_key/5`).
  #
  # `layout?/1` is whether a name is one of these, every segment of it a component of the
  # distribution name grammar, and at most 255 bytes long: a token never has an entry
  # whose name fails it, an empty name included.

  @hex16 "[0-9a-f]{16}"
  @component "[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"
  @upstream_hosts ~w(docker.io ghcr.io mcr.microsoft.com quay.io)
  @upstream Enum.map_join(@upstream_hosts, "|", &Regex.escape/1)

  @scoped ~r/\A#{@hex16}\/#{@hex16}\/(environments|targets)\/#{@hex16}\z/
  @shared ~r/\Ashared(\/#{@component})+\z/
  @upstream_name ~r/\Aupstream\/(#{@upstream})(\/#{@component})+\z/
  @instance ~r/\A#{@hex16}\z/

  @key_label "qory registry environment key v1"

  @doc false
  @spec upstream_hosts() :: [String.t()]
  def upstream_hosts, do: @upstream_hosts

  @doc false
  # instance?/1 is whether `name` is an instance's registry name: 16 lower-case hex
  # digits, so never `shared` nor `upstream`.
  @spec instance?(term) :: boolean
  def instance?(name), do: is_binary(name) and Regex.match?(@instance, name)

  @doc false
  @spec organisation(Ecto.UUID.t()) :: String.t()
  def organisation(organisation_id) when is_binary(organisation_id), do: hex16(organisation_id)

  @doc false
  @spec target(String.t()) :: String.t()
  def target(public_id) when is_binary(public_id), do: hex16(public_id)

  @doc false
  # target_name/3 is the name of a target's image.
  @spec target_name(String.t(), Ecto.UUID.t(), String.t()) :: String.t()
  def target_name(instance, organisation_id, target_public_id),
    do: scoped(instance, organisation_id, "targets", target(target_public_id))

  @doc false
  # environment_name/3 is the name of an environment image for `key`.
  @spec environment_name(String.t(), Ecto.UUID.t(), String.t()) :: String.t()
  def environment_name(instance, organisation_id, key),
    do: scoped(instance, organisation_id, "environments", key)

  @doc false
  # environment_key/5 is `<key>`, as the comment after the moduledoc encodes it.
  @spec environment_key(Ecto.UUID.t(), String.t(), String.t(), [String.t()], [String.t()]) ::
          String.t()
  def environment_key(organisation_id, environment_ref, machine, egress_hosts, credential_hosts) do
    [
      @key_label,
      organisation_id,
      environment_ref,
      machine,
      egress_hosts |> Enum.uniq() |> Enum.sort(),
      credential_hosts |> Enum.uniq() |> Enum.sort()
    ]
    |> Jason.encode!()
    |> hex16()
  end

  @doc false
  # layout?/1 is whether `name` is a name of the layout (see the moduledoc).
  @spec layout?(term) :: boolean
  def layout?(name) when is_binary(name) and byte_size(name) in 1..255,
    do: Regex.match?(@scoped, name) or shared?(name) or upstream?(name)

  def layout?(_name), do: false

  @doc false
  @spec shared?(term) :: boolean
  def shared?(name),
    do: is_binary(name) and byte_size(name) <= 255 and Regex.match?(@shared, name)

  @doc false
  @spec upstream?(term) :: boolean
  def upstream?(name),
    do: is_binary(name) and byte_size(name) <= 255 and Regex.match?(@upstream_name, name)

  defp scoped(instance, organisation_id, kind, hex) do
    true = instance?(instance)
    "#{instance}/#{organisation(organisation_id)}/#{kind}/#{hex}"
  end

  defp hex16(value),
    do: :crypto.hash(:sha256, value) |> binary_part(0, 8) |> Base.encode16(case: :lower)
end
