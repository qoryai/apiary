defmodule Apiary.Adapters.Installed do
  # The adapters installed with Qory Apiary: those the setting `QORY_INSTALLED_ADAPTERS`
  # lists by name (`names/0`), which run beside the instance, in the same Compose project
  # or stack, and reach it with a key they make themselves, from a one-time code Qory Apiary
  # writes for them to `QORY_ENROLMENT_DIR` (`dir/0`), as `<name>/code`, in a folder per
  # adapter, which only that adapter mounts (`Apiary.Adapters.Installed.CodeFile`). No
  # person runs a command for them.
  #
  # **The setting.** Names separated by commas, each a lower-case letter, then lower-case
  # letters, digits and hyphens, 32 characters at most (`valid_name?/1`), none twice;
  # unset or blank names none. `config/runtime.exs` keeps the value as it is, and `boot!/0`
  # checks it when the application starts, after the features (`Apiary.Features.boot!/0`):
  # a malformed name, a name listed twice, or any name on an instance without the feature
  # `factory`, stops the boot. The list is fixed while the instance runs. `boot!/0` stops
  # the boot too on a `QORY_ENROLMENT_DIR` that is set and is not an absolute path, names
  # listed or not.
  #
  # **The folders.** Right after `boot!/0`, `make_folders/0` makes the folder of each name
  # listed where it is missing, so that an adapter that mounts it finds it as soon as the
  # instance has booted, before it is set up. A folder it cannot make is said in the log
  # and does not stop the boot: a write of a code makes it again.
  #
  # **What follows from it.** Once the instance is set up, the installer
  # (`Apiary.Adapters.Installer`) makes one adapter for each name listed
  # (`Apiary.Adapters.install/2`, the instance's `adapter.install`): its node's
  # `installed_as` is the name, its name the name, or `-2`, `-3` and on after it where an
  # adapter in use has that name. While it holds no key, the installer keeps one valid code
  # for it in its file (`Apiary.AccessKeys.issue_installed_code/2`); once a key is live, the
  # file is deleted. An installed adapter holds one key at most, gets no code from a person,
  # and enrols with a code that names no maker only while it is listed. It is not removed
  # while it is listed (`Apiary.Adapters.delete_adapter/2`). A name taken off the list
  # removes nothing: the adapter, its keys and its connections stay, its outstanding codes
  # are cancelled and its file deleted, and an instance admin may then remove it. A name
  # listed again finds the adapter in use that is installed as it, or, once that one was
  # removed, makes a new one.
  #
  # **The nudge.** A change that should bring a code at once, the revocation of an
  # installed adapter's key, broadcasts on `topic/0` once it commits (`nudge/0`); the
  # installer, which otherwise passes every 10 seconds, passes at once.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  require Logger

  alias Apiary.Adapters.Installed.CodeFile

  @default_dir "/run/qory/enrolment"
  @name ~r/\A[a-z][a-z0-9-]{0,31}\z/
  @topic "adapters:installed"

  @doc false
  # The names of the adapters installed with Qory Apiary, as `boot!/0` fixed them, in the
  # order the setting lists them. Before `boot!/0`, as under `bin/apiary eval`, the setting
  # read and checked now, but for the feature, which raises as `boot!/0` does.
  @spec names() :: [String.t()]
  def names do
    case Application.fetch_env(:apiary, :installed_adapters) do
      {:ok, names} -> names
      :error -> setting() |> parse() |> names!()
    end
  end

  @doc false
  # listed?/1 says whether `name` is one of `names/0`.
  @spec listed?(term) :: boolean
  def listed?(name) when is_binary(name), do: name in names()
  def listed?(_name), do: false

  @doc false
  # The directory the codes are written to: `QORY_ENROLMENT_DIR`, else
  # /run/qory/enrolment when it is unset or blank.
  @spec dir() :: String.t()
  def dir do
    case Application.get_env(:apiary, :enrolment_dir_setting) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: @default_dir, else: String.trim(value)

      _unset ->
        @default_dir
    end
  end

  @doc false
  # valid_name?/1 says whether `name` may be listed: a lower-case letter, then lower-case
  # letters, digits and hyphens, 32 characters at most, as `nodes_installed_as_check` has it.
  @spec valid_name?(term) :: boolean
  def valid_name?(name) when is_binary(name), do: name =~ @name
  def valid_name?(_name), do: false

  @doc false
  # The names a value of `QORY_INSTALLED_ADAPTERS` lists, in its order: `{:ok, names}`, none
  # for nil, an empty or a blank value; `{:error, reason}` for an empty name between commas,
  # a malformed name or one listed twice.
  @spec parse(String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse(nil), do: {:ok, []}

  def parse(value) when is_binary(value) do
    if String.trim(value) == "" do
      {:ok, []}
    else
      names = value |> String.split(",") |> Enum.map(&String.trim/1)

      cond do
        bad = Enum.find(names, &(not valid_name?(&1))) ->
          {:error,
           "#{inspect(bad)} is not a name: a lower-case letter, then lower-case letters, " <>
             "digits and hyphens, 32 characters at most, separated by commas"}

        twice = names |> Enum.frequencies() |> Enum.find(fn {_name, n} -> n > 1 end) ->
          {:error, "#{elem(twice, 0)} is listed twice"}

        true ->
          {:ok, names}
      end
    end
  end

  @doc false
  # Reads `QORY_INSTALLED_ADAPTERS` as `config/runtime.exs` left it, checks it and fixes
  # the names for the life of the node. Called at boot, after the features: raises on a
  # value `parse/1` refuses, on a list of any name while the instance does not have the
  # feature `factory`, and on a `QORY_ENROLMENT_DIR` set to a path that is not absolute,
  # so the instance does not start.
  @spec boot!() :: [String.t()]
  def boot! do
    names = setting() |> parse() |> names!()
    dir!()

    if names != [] and not Apiary.Features.on?(:factory) do
      raise ArgumentError, """
      environment variable QORY_INSTALLED_ADAPTERS names adapters, and this instance does
      not have the feature they belong to: QORY_FEATURES leaves it out.
      Leave QORY_INSTALLED_ADAPTERS unset, or turn the feature on in QORY_FEATURES.
      """
    end

    Application.put_env(:apiary, :installed_adapters, names)
    names
  end

  # A `QORY_ENROLMENT_DIR` set to a relative path names a directory that moves with the
  # working directory: refused, names listed or not, as a pass deletes codes there for the
  # names taken off the list too. Unset and blank keep the default, which is absolute.
  defp dir! do
    dir = dir()

    if Path.type(dir) != :absolute do
      reason = "#{inspect(dir)} is not an absolute path"

      raise ArgumentError, """
      environment variable QORY_ENROLMENT_DIR is not valid: #{reason}.
      Leave it unset for #{@default_dir}, or give the full path of a directory, for example:
      QORY_ENROLMENT_DIR=#{@default_dir}
      """
    end

    :ok
  end

  @doc false
  # Makes the folder of each name `names/0` lists where it is missing
  # (`Apiary.Adapters.Installed.CodeFile.make_folder/1`). Called at boot, right after
  # `boot!/0`. A folder it cannot make is said in the log, one line for each, with the
  # reason alone, and stops nothing: the write of a code makes it again. `:ok`.
  @spec make_folders() :: :ok
  def make_folders do
    for name <- names() do
      case CodeFile.make_folder(name) do
        :ok -> :ok
        {:error, reason} -> Logger.error(folder_line(name, reason))
      end
    end

    :ok
  end

  @doc false
  # The line that says the folder of the adapter installed as `name` could not be made.
  @spec folder_line(String.t(), atom) :: String.t()
  def folder_line(name, reason),
    do:
      "could not make the folder of the installed adapter #{name}, #{CodeFile.folder(name)}: " <>
        "#{CodeFile.format_error(reason)}; trying again when its one-time code is written"

  defp setting, do: Application.get_env(:apiary, :installed_adapters_setting)

  defp names!({:ok, names}), do: names

  defp names!({:error, reason}) do
    raise ArgumentError, """
    environment variable QORY_INSTALLED_ADAPTERS is not valid: #{reason}.
    Leave it unset for none, or name the adapters, for example:
    QORY_INSTALLED_ADAPTERS=tracker
    """
  end

  @doc false
  # The topic the installer listens on for a nudge.
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc false
  # Asks the installer to pass at once (`Apiary.Adapters.Installer`): after a change that
  # should bring an installed adapter a code without waiting, once that change committed.
  # The message carries nothing.
  @spec nudge() :: :ok
  def nudge, do: Phoenix.PubSub.broadcast(Apiary.PubSub, @topic, :nudge)
end
