defmodule ApiaryPro.Gateways do
  # Gateways is the edition's answer to which organisations' organisation-level
  # gateways may serve which workspaces (`c:Apiary.Edition.serving_organisations/1`,
  # `c:Apiary.Edition.served_organisations/1`), which `Apiary.Gateways` asks.
  #
  # While an operator runs its clients' infrastructure (the flag
  # `ApiaryPro.Flags.operator_infrastructure?/0`), an operator's organisation-level
  # gateways serve the workspaces of its clients as well as the operator's workspaces:
  #
  # - `serving_organisations/1` of a client is its operator, so a client's workspace
  #   resolves its default from the workspace, then the client, then its operator, then
  #   none;
  # - `served_organisations/1` of an operator is its clients, in the order of their ids.
  #
  # Otherwise both answer `[]`, and an organisation's gateways serve the workspaces of that
  # organisation alone.
  #
  # While the flag is on, a node or a node pool in a client's workspace may name one of
  # its operator's organisation-level gateways; another operator's clients may not, and
  # the core's check of the choice answers "is not a gateway this node may use". The
  # core's rules of the default hold across the organisations: a new gateway becomes its
  # organisation's default only when no workspace it serves resolves a default at its
  # level or after, a gateway that nodes or runs still use is not deleted, wherever those
  # nodes are, and after a deletion no node moves.
  #
  # Who sees to them, while the flag is on. At the operator, its owners and admins add,
  # change, mark as the default and delete its organisation-level gateways and see to
  # their access keys, and its members read them, as at any organisation; the client's
  # people do not reach the operator, so for them the operator's gateways are not there.
  # At a client, its organisation-level gateways are the operator's to see to, as its
  # nodes and node pools are: only the operator's owners and admins add, change and delete
  # them and their keys, and the client's people read them and find nothing to change
  # (`ApiaryPro.Access`). The client's people see which gateway each of its nodes uses,
  # and change none.
  #
  # Suspension, while the flag is on. While an operator is suspended its clients keep
  # running, through its gateways too: the key of the operator's organisation-level
  # gateway is still verified, and acts for a run of a client's workspace, whose place is
  # in use. It acts for no run of the operator's workspaces, whose place is not, so their
  # runs through it are refused, as every key of a node of a suspended organisation is. A
  # suspended client's runs are refused at the client's place, as before.
  #
  # The lock order, while the flag is on (docs/access.md, The lock order). A change of an
  # organisation-level gateway holds the organisations it serves, an operator's clients,
  # `FOR SHARE`, and a change at a workspace holds those that serve it, a client's
  # operator, `FOR SHARE` (`Apiary.Gateways.lock/1`). So a change of an operator's gateway
  # and a node written in one of its clients take turns on the operator's row. A client's
  # creation (`ApiaryPro.Operators.create_client/3`) and the operator's suspension lock
  # the operator `FOR NO KEY UPDATE`, and a grant of the operator's features
  # (`ApiaryPro.Grants.set_organisation/3`) its clients and then the operator: each waits
  # for a change of the operator's gateways or is waited for. A grant to a client
  # (`ApiaryPro.Grants.set_client/3`) locks the client `FOR NO KEY UPDATE` and waits for a
  # node written in it, or is waited for. A policy write in a client holds the client and
  # its operator `FOR SHARE`, as a node written there does, so the two go together and
  # each waits for a change of the operator's gateways. The organisations a change of
  # gateways locks are read before the lock, and not read again: every change of the
  # relation takes a row the change of gateways takes too, in a mode that conflicts with
  # it. A client's creation locks the operator, against the operator's row a change of its
  # gateways locks or holds; a client's drop locks the client `FOR NO KEY UPDATE`, against
  # the client's row a node written there holds `FOR SHARE`. So a client created between
  # the read and the lock holds no node yet, and one dropped waits for the node written in
  # it (`test/apiary_pro/gateway_races_test.exs`).
  #
  # Both come from one relation, the client's operator (`ApiaryPro.Tenants`,
  # `operator_id`), so each is the reverse of the other: X is among
  # `serving_organisations(Y)` exactly when Y is among `served_organisations(X)`. Each is
  # one read, which locks nothing: a change of gateways takes the organisation rows they
  # name (`Apiary.Gateways.lock/1`). Neither names the organisation itself, as an operator
  # is never a client. Neither asks whether an organisation is suspended or marked for
  # deletion: the core checks a run's place where it matters, at the server contract, and
  # a suspension never moves a node on its default to another gateway.
  @moduledoc """
  Gateways is the edition's answer to the core's questions of which other
  organisations' organisation-level gateways may serve an organisation's workspaces
  (`c:Apiary.Edition.serving_organisations/1`,
  `c:Apiary.Edition.served_organisations/1`), which `Apiary.Gateways` asks.
  """

  import Ecto.Query, warn: false

  alias Apiary.Repo
  alias ApiaryPro.Flags
  alias ApiaryPro.Tenants.Tenant

  # serving_organisations/1 is the organisations whose organisation-level gateways may
  # serve the workspaces of the organisation `organisation_id`, besides that
  # organisation's, in the order its workspaces resolve their default through them: its
  # operator, for a client, while an operator runs its clients' infrastructure; `[]`
  # otherwise.
  @doc false
  @spec serving_organisations(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def serving_organisations(organisation_id) when is_binary(organisation_id) do
    if Flags.operator_infrastructure?() do
      Repo.all(
        from t in Tenant,
          where: t.organisation_id == ^organisation_id and not is_nil(t.operator_id),
          select: t.operator_id
      )
    else
      []
    end
  end

  # served_organisations/1 is the organisations whose workspaces the organisation-level
  # gateways of the organisation `organisation_id` may serve, besides that organisation's,
  # by id: its clients, for an operator, while an operator runs its clients'
  # infrastructure; `[]` otherwise.
  @doc false
  @spec served_organisations(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def served_organisations(organisation_id) when is_binary(organisation_id) do
    if Flags.operator_infrastructure?() do
      Repo.all(
        from t in Tenant,
          where: t.operator_id == ^organisation_id,
          order_by: [asc: t.organisation_id],
          select: t.organisation_id
      )
    else
      []
    end
  end
end
