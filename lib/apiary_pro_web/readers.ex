defmodule ApiaryProWeb.Readers do
  @moduledoc """
  What the edition's pages, and the core's through the edition
  (`c:ApiaryWeb.Edition.reader_sentence/2`), say to a person who reads an organisation
  through the edition's reach and changes nothing there: an instance admin, who reads every
  other organisation of the instance, and a person of a client's operator, who reads the
  client (`ApiaryPro.Reach`).
  """
  use Gettext, backend: ApiaryProWeb.Gettext

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation

  @doc """
  sentence/2 is what a page says of the reader of `scope`: `:refused`, the sentence of a
  change refused to a person who reaches the organisation as an instance admin or through
  its operator. Nil for anyone else, and for `:level`, which the core no longer asks: the
  account menu's line it was is gone, and the notices say how a reader reads
  (`ApiaryProWeb.Notices`).
  """
  @spec sentence(:level | :refused, Scope.t()) :: String.t() | nil
  def sentence(:refused, scope) do
    case Access.reach(scope) do
      :instance ->
        gettext("You can read this organisation as support, and change nothing here.")

      :operator ->
        # While the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`),
        # its owners and admins do not read only: the sentence is its members' alone.
        if not ApiaryPro.Flags.operator_infrastructure?() or
             ApiaryPro.Reach.operator_level(scope) not in [:owner, :admin],
           do:
             gettext(
               "You can read this organisation as a person of its operator, and change nothing here."
             )

      _other ->
        nil
    end
  end

  def sentence(_where, _scope), do: nil

  @doc """
  operator_name/1 is the name of the operator the person of `scope` reads a client
  through, where the scope carries it: `Apiary.Organisations.resolve_scope/4` loads it
  with their membership there. Nil otherwise.
  """
  @spec operator_name(Scope.t() | nil) :: String.t() | nil
  def operator_name(%Scope{reach: {:operator, %{organisation: %Organisation{name: name}}}}),
    do: name

  def operator_name(_scope), do: nil
end
