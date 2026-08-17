h2. Document Superset capability and limititations

h3. Objective

Document the capabilities, limitations and implementation feasibility of Apache Superset 6.0 for the planned BI dashboard redesign, with ClickHouse as the analytical/serving database.

h3. Scope

* Review Superset 6.0 capabilities for dashboarding, Explore, SQL Lab, datasets, metrics, filters, RLS, alerts, reports, caching, APIs and exports.
* Assess feasibility against:
  ** WAON POINT Dashboard Redesign Plan v0.1
  ** Merchant Analysis Dashboard Redesign Plan v0.4(2)
* Compare the expected user experience with the existing Looker workflow.
* Document the observed Superset limitations:
  ** SQL Lab does not provide a Looker-style total row count.
  ** SQL Lab result display is controlled by the selected query limit; the observed UI exposes values up to 100,000 rows.
  ** Dataset import may fail with “Could not find a valid command to import file”.
* Define practical workarounds, risk controls and mandatory spikes before implementation.
* Clarify the system boundary: ClickHouse executes analytical queries; Superset provides the query, exploration and visualization layer; metadata database, cache and workers are supporting components.

h3. Deliverables

* Vietnamese document: *Superset 6.0 Capabilities and Limitations — v0.5*
* English document: *Superset 6.0 Capabilities and Limitations — v0.5*
* Include the four user-provided Superset/Looker screenshots as UI evidence with captions.
* Preserve document version history for future updates.

h3. Acceptance Criteria

* Both Vietnamese and English documents are completed and versioned as v0.5.
* ClickHouse is explicitly identified as the analytical/serving database.
* The 100,000-row limit and missing total-row-count behavior are clearly documented.
* The dataset import error is documented with its recommended workaround.
* Feasibility and limitations are mapped to the two dashboard redesign plans.
* Risks, prerequisites, performance considerations, security/RLS considerations and required spikes are included.
* Both documents are reviewed for readability, references, image placement and layout quality.
