defmodule ApiaryProWeb.Readers do
  @moduledoc """
  What the edition's pages, and the core's through the edition
  (`c:ApiaryWeb.Edition.reader_sentence/2`), say to a person who reads an organisation
  through the edition's reach and changes nothing there: an instance admin, who reads every
  other organisation of the instance, and a person of the operator of a workspace, who reads
  that workspace (`ApiaryPro.Reach`).
  """
  use Gettext, backend: ApiaryProWeb.Gettext

  alias Apiary.Access
  alias Apiary.Accounts.Scope

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
        # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, the operator's owners and
        # admins do not read only: the sentence is its members' alone.
        if not ApiaryPro.Flags.operator_infrastructure?() or
             ApiaryPro.Reach.operator_level(scope) not in [:owner, :admin],
           do:
             gettext(
               "You can read this workspace as a person of its operator, and change nothing here."
             )

      _other ->
        nil
    end
  end

  def sentence(_where, _scope), do: nil
end
