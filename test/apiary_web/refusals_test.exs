defmodule ApiaryWeb.RefusalsTest do
  # Every change the core's pages offer, sent through the web layer by someone who may not
  # make it: a member, an admin where only an owner may, a person whose page was opened
  # before their level changed or they were removed, and an owner of another organisation
  # carrying the ids of this one. One row per attempt, in `ApiaryWeb.RefusalsRows`, sent
  # by `ApiaryWeb.RefusalsCase`, which asserts that each is refused, that nothing of the
  # organisation changed in the database and that no audit entry was written, and fails
  # for an action of the core that changes something and has no row. An edition's own
  # test sends these rows again, under the edition, beside its own.
  # Not async, as no test of the case is: an edition's rows may write through the
  # instance's own organisation, committed once outside the sandbox, whose row and owners
  # they lock (docs/conventions.md, Tests).
  use ApiaryWeb.RefusalsCase, rows: [ApiaryWeb.RefusalsRows], covers: :core
end
