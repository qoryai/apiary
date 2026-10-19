defmodule Apiary.Repo.Migrations.KeepTheDomainsAnAdapterServes do
  use Ecto.Migration

  # An adapter's `domains`, as its latest start's description lists them (the integration
  # contract's `description.schema.json`): the kinds of work it serves, each a domain's
  # name. NULL where the description lists none, which serves every domain, and on every
  # node that is not an adapter (`nodes_domains_check`). A person who picks for a
  # workspace picks among the adapters that serve its domain
  # (`Apiary.Adapters.Collections.assign_collections/4`).
  #
  # Every row there already gets NULL: an adapter's next start writes its list.
  def up do
    alter table(:nodes) do
      add :domains, {:array, :text}
    end

    create constraint(:nodes, :nodes_domains_check,
             check: "domains IS NULL OR (kind = 'adapter' AND cardinality(domains) >= 1)"
           )
  end

  def down do
    drop constraint(:nodes, :nodes_domains_check)

    alter table(:nodes) do
      remove :domains
    end
  end
end
