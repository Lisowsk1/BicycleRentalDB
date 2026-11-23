The Bicycle Sharing System enables users to rent and return bicycles at
designated stations. The system supports both regular and electric
bicycles and provides information about their availability at each
station, taking maintenance status and battery levels into account. It
also allows staff to manage bicycles, stations, maintenance operations,
and user accounts, and to assist with returns. Rental records are
maintained to track bicycle usage and rental history. The system
calculates rental charges and records payment outcomes through a
simulated payment service. An audit log records important administrative
changes.

\*System Entities and Attributes

::: longtable
\|L35mm\|L75mm\|L146mm\| **Entity** & **Purpose** & **Main attributes**\

**Entity** & **Purpose** & **Main attributes**\

**Account** & Stores the common account information shared by Rider and
Staff. & `first_name`, `last_name`, `email`, `password_hash`, `role`\

**Rider** & Extends Account with rider-specific status and blocking
information. & Inherits Account attributes; adds `status`,
`block_reason`.\

**Staff** & Represents staff members as a subtype of Account who perform
administrative operations. & No additional attributes; inherits Account
attributes.\

**Station** & Represents a bicycle station with geographic information
and independent rental and return controls. & `name`, `address`,
`latitude`, `longitude`, `rental_enabled`, `return_enabled`\

**Bicycle** & Represents a bicycle, including its type, maintenance
state and current placement. & `identifier`, `bicycle_type`,
`maintenance_state`, `placement`\

**ElectricBicycle** & Extends Bicycle with battery-level information
specific to electric bicycles. & Inherits Bicycle attributes; adds
`battery_percentage`.\

**Rental** & Records a rider's use of a bicycle, including rental times
and the pricing information captured when the rental begins. &
`start_time`, `end_time`, `captured_price_per_block`,
`captured_block_length_seconds`, `captured_currency`, `final_charge`\

**MaintenanceProvider** & Represents an internal maintenance team or an
external provider responsible for servicing bicycles. & `name`,
`contact_email`, `contact_phone`, `is_active`\

**FaultReport** & Records a reported bicycle fault, including its
classification, severity and resolution status. & `category`,
`severity`, `description`, `status`, `reported_at`, `resolved_at`\

**MaintenanceJob** & Records a maintenance session for a bicycle,
including its status, progress and resolution information. & `status`,
`opened_at`, `started_at`, `closed_at`, `resolution`\

**MaintenanceTask** & Represents an individual inspection, repair or
other maintenance task performed within a maintenance job. &
`task_type`, `description`, `outcome`, `completed_at`\

**Tariff** & Defines the pricing rules applied to bicycle rentals
according to bicycle type. & `bicycle_type`, `price_per_block`,
`block_length_seconds`, `currency`\

**Payment** & Records the payment amount, currency and processing status
associated with a rental. & `amount`, `currency`, `status`,
`created_at`, `updated_at`\

**BicycleTransfer** & Records the movement of a bicycle between stations
by a staff member, including the transfer time and reason. &
`transferred_at`, `reason`\

**AuditEntry** & Records an action performed by a staff member on a
supported business record. & `action_type`, `primary_record_type`,
`primary_record_id`, `created_at`\

**AuditDetail** & Stores field-level information about changes
associated with an audit entry, including previous and new values. &
`subject_record_type`, `subject_record_id`, `field_name`,
`previous_value`, `new_value`\
:::

Targets are stated at the 99th percentile (P99).

::: longtable
\|C15mm\|L51mm\|L75mm\|C28mm\|L73mm\| **Priority Level** &
**Functionality** & **Reason** & **Max Time under Peak Load** & **Max
Time Choice explanation**\
**Priority Level** & **Functionality** & **Reason** & **Max Time under
Peak Load** & **Max Time Choice explanation**\
& Rental Start & Return & The main functionality, Payment is based on
rental duration. & $< 3\,\mathrm{s}$ & The time should be as low as
possible, but under heavy load may queue up.\
& Current Active Rental Lookup & Lets a rider recover after an uncertain
start response. & $< 3\,\mathrm{s}$ & A lookup of one rider's current
state must respond within three seconds under peak load to support
prompt recovery.\
& Staff-assisted Return & A staff member completes a rider's return and
waits for the result. & $< 3\,\mathrm{s}$ & Follows the same completion
rules as a normal return and must respond within three seconds under
peak load.\
& Stations & Vehicles Search / Availability Queries & The main
functionality, but acceptable to be outdated if multiple actions are
taken on the same vehicle simultaneously. & $< 6\,\mathrm{s}$ &
Important, but under load can be computationally demanding, and users
could search beforehand.\
& Staff Operations (Handovers, Transfers, Maintenance) & Not the main
functionality, but still performed by humans who have to wait for it. &
$< 6\,\mathrm{s}$ & Should not be under as much pressure as client-sided
functionalities, but load could spill causing delays.\
& Battery Updates & Background/ batch updates, but crucial for correct
functionality. & $< 300\,\mathrm{s}$ & Won't affect live user actions,
but processing must be kept steady to keep the vehicles operating
correctly.\
& Rental / Maintenance History updates & Automatic, not urgent. &
$< 300\,\mathrm{s}$ & Purely analytical, doesn't matter that much.\
:::

::: longtable
\|L50mm\|L75mm\| **Entity** & **Keep for**\

**Entity** & **Keep for**\

AuditEntry & 36 months after creation\
AuditDetail & 36 months, together with AuditEntry\
Rental & 24 months after completion\
Payment & 24 months after rental deletion\
FaultReport & 36 months after resolution\
MaintenanceJob & 36 months after closing\
MaintenanceTask & 36 months, together with MaintenanceJob\
BicycleTransfer & 36 months after transfer\
:::

\*User Registration and Account Details

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-001** & Won't have this stage & **Account details**

The database shall store each account's first name, last name, email
address, and password hash. & All fields are required. Names containing
only whitespace are rejected. Password storage follows the
password-hashing requirement below.\

**F-002** & Won't have this stage & **Unique email addresses**

Email addresses shall be unique across rider and staff accounts after
trimming surrounding whitespace and treating capitalization as
insignificant. & Equivalent emails are rejected, including during
concurrent creation. Dots and +suffixes remain significant.\

**F-003** & Won't have this stage & **Registration validation**

Public rider registration shall accept first name, last name, email
address, and password within the implementation handling the request. &
Missing fields, blank names, an email empty after trimming, and an empty
password reject. Email matching follows F-002. Supplying an account
identity, password hash, role, or rider status rejects. Public
registration cannot create staff accounts.\

**F-004** & Won't have this stage & **Registration persistence**

The server shall atomically create a rider account with a stable
identity, active status, and password hashed under F-001, F-005. &
Duplicate email addresses across riders/staff reject, including
concurrent registration. Hashing or persistence failure leaves no
partial account. Successful registration returns no password/hash and
does not create a session; the rider signs in under F-006--F-007.\

**F-087** & Should have & **Email display value.**

The system shall store each email address in the form entered while
applying the F-002 equivalence (trimmed, case-insensitive) for
uniqueness and lookup. & The stored display value keeps its original
capitalization. Equivalent emails that differ only in case are rejected
at registration. Login by an equivalent email succeeds.\
:::

\*User Login and Authentication

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-005** & Won't have this stage & **Password hashing**

The system shall hash and verify passwords using a maintained
password-hashing library with an independent salt for each password and
equivalent documented algorithm/work settings across implementations. &
Plaintext passwords are never persisted. Passwords are not trimmed,
normalized, case-folded, or silently truncated. Raw passwords and hashes
are never returned by user-facing interfaces or written to application
logs or audit entries. Staff setup uses the same rules.\

**F-006** & Won't have this stage & **Credential verification**

The system shall authenticate riders and setup-provisioned staff by
email and password within each separate implementation, using standard
authentication/session libraries. & Email lookup follows F-002. Password
verification follows F-001, F-005 without altering the password. Missing
credentials reject. Unknown email and incorrect password return the same
generic invalid-credentials response and create no session. A blocked
rider with correct credentials may log in.\

**F-007** & Won't have this stage & **Session issuance**

Successful login shall issue a fresh server-generated session bound to
the verified account and the issuing implementation under F-008--F-011.
& Client-supplied session credentials, roles, or account overrides
cannot replace the verified account identity, its permissions, or the
fresh server-issued session credential. Login returns no password/hash.
Staff authentication does not make the staff account eligible to rent as
a rider.\

**F-008** & Won't have this stage & **Session validation**

Sessions shall use server-issued unguessable credentials and bind one
account to the separate implementation that issued the session. The
server shall validate the session on every protected request under
F-014--F-016. & Invalid, revoked, expired, or other-implementation
credentials reject at the protected operation boundary. Client edits
cannot change the account, role, or validity. Session credentials are
excluded from application logs and audit entries.\

**F-009** & Won't have this stage & **Session expiry**

Sessions shall expire after a fixed setup-configured lifetime measured
from login using trusted server time. The default lifetime is 30 minutes
and shall be equivalent across implementations. & At or after expiry,
the session cannot authorize requests. Activity does not extend expiry.
Client clock changes cannot extend validity. A new login is required
after expiry.\

**F-010** & Won't have this stage & **Logout**

Logout shall revoke the presented session server-side and clear its
client-side authenticated state. & Reusing the revoked session fails.
Repeated logout may acknowledge an already logged-out state without
revealing account data. Logout affects the presented session.\

**F-011** & Won't have this stage & **Business state after session
termination**

Logout or session expiry shall leave existing rental, charge, and
payment records unchanged. & Neither event ends a rental or undoes a
committed operation. After logging in again, the rider can retrieve
current rental/payment state through F-049, F-067--F-068.\
:::

\*User Roles, Permissions, and Rider Status

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-012** & Must have & **Rider status**

Each rider shall have exactly one status: active or blocked. Newly
registered riders shall be active. & Unsupported statuses are rejected;
registration creates an active rider.\

**F-013** & Won't have this stage & **Account roles**

Each account shall have exactly one role, rider or staff, which
supported operational interfaces shall not change. Rider registration
assigns the rider role server-side; staff accounts are provisioned only
during privileged setup. & Missing or unsupported stored roles, multiple
roles, and operational role-change attempts are rejected. Public
registration cannot create a staff account or use client-supplied
role/status fields to bypass F-003--F-004. The database account identity
and role are authoritative for server-side authorization; the client
cannot choose its permissions.\

**F-014** & Won't have this stage & **Authenticated operation boundary**

All user-facing operations except registration, login, and idempotent
logout shall require a valid server-verified session. Each separate
implementation shall validate its own sessions and derive the actor and
role from the validated session. & Missing, invalid, revoked, expired,
or other-implementation sessions reject protected access before
disclosure or mutation. Client-supplied actor IDs, roles, or
authentication state cannot override the session. All supported request
paths receive the same checks. Setup/reset and the trusted simulator
adapter have separate trusted boundaries.\

**F-015** & Won't have this stage & **Role and ownership checks**

The server shall enforce the required role and record ownership on each
protected request. & Riders may start/return only their own rentals and
access/pay only their own eligible rental data. Station and availability
queries are available to either authenticated role. Staff may perform
explicitly staff-authorized functions, including F-077--F-081 and
F-067--F-068, but cannot initiate rider payments or rent as riders.
Target IDs identify records, not the acting account. Unauthorized
requests disclose no protected data and make no business-state changes.\

**F-016** & Won't have this stage & **Rider blocking and access**

Only authorized staff shall block or unblock a rider. Blocking shall
prevent new rentals while preserving login and access to existing
rental/payment operations. & An otherwise valid session remains usable
after blocking. A blocked rider can retrieve their active rental, return
it, view their own permitted data, and pay an existing charge. Active
rentals and history remain unchanged. Blocking/unblocking is audited
under F-071--F-072. New rentals check current rider status under F-039
and R-006.\
F-088 & Could have & **Block reason.** When staff block a rider, they
may supply an optional block reason, stored with the rider. & Blocking
works with or without a reason. A reason is never required for the
status change. The handling of the reason on unblocking is documented
and identical across implementations.\
F-089 & Should have & **Staff administration permissions.** Only staff
shall administer maintenance providers, maintenance jobs and tasks, and
fault reports (review, resolution, assignment). & A rider request for
any of these operations is rejected without disclosure or change. Staff
requests are authorized from the session role.\
F-090 & Should have & **Provenance fields are not authorization.** The
reporting account on a fault report and the assigned staff member on a
job shall record authorship and responsibility only. & Neither field
grants permission. The session actor and role check (F-014, F-015) are
applied to every request. Client-supplied values cannot replace the
session actor.\
:::

\*Station Information and Management

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-017** & Must have & **Station location**

Each station shall have a required name, address/location description,
latitude, and longitude. & Names/descriptions cannot be blank. Latitude
is within -90 to 90; longitude within -180 to 180.\

**F-018** & Must have & **Station controls**

Each station shall have independent rental-enabled and return-enabled
controls. & All four combinations can be represented.\

**F-019** & Must have & **Station listing**

Station queries shall return location information and rental/return
controls, including empty and disabled stations. & Such stations remain
in results with their control values.\

**F-020** & Should have & **Station creation**

Authorized staff shall create a station with all location fields in
F-017 and explicit values for both controls in F-018. & Creation assigns
a stable identity under F-086 and commits with its audit entry under
F-075. A new station appears in station listings even when either or
both controls are disabled.\

**F-021** & Could have & **Station updates**

Authorized staff shall update station descriptions, correct location
information, and change rental/return controls while preserving station
identity. & Updates satisfy F-017, F-018 and commit with their audit
entry under F-075. Historical rental references display current station
descriptions. A physically different station requires a new record;
changing coordinates under an existing identity is for corrections, not
physical relocation.\
:::

\*Bicycle Information, Placement, and Transfers

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-022** & Must have & **Bicycle identifiers**

Each bicycle shall have a required visible identifier unique across all
bicycles after trimming surrounding whitespace and comparing
case-insensitively. A display value shall be preserved. & Blank and
equivalent identifiers are rejected, including under concurrent
creation. The same equivalence rules apply to identifier lookup and
imports across all implementations.\

**F-023** & Must have & **Bicycle types**

Each bicycle shall have exactly one type: regular or electric. & Missing
or unsupported types are rejected.\

**F-024** & Must have & **Bicycle placement**

Every bicycle shall have exactly one placement: at a station, on an
active rental, or with the maintenance provider. & Placements are
mutually exclusive and exhaustive. A bicycle has rental placement if and
only if it has exactly one active rental. A bicycle with station or
maintenance-provider placement has no active rental.\

**F-025** & Must have & **Current station references**

A bicycle shall reference exactly one existing current station if and
only if its placement is at a station. Bicycles on an active rental or
with the maintenance provider shall have no current station. Each rental
shall retain its pickup-station reference. & Invalid station references,
missing stations for station placement, and current stations for other
placements are rejected. Later bicycle movements do not change an
earlier rental's pickup-station reference.\

**F-026** & Should have & **Bicycle creation**

Authorized staff shall create a bicycle at an existing station with an
identifier, type, explicit valid maintenance state, and applicable
battery value under F-022, F-023, F-028, and F-032. & Incomplete or
inconsistent inputs reject. Operational creation directly on a rental or
with the provider rejects. Privileged baseline loading may establish
other valid placements and existing rentals.\

**F-027** & Could have & **Station transfers**

Authorized staff shall transfer bicycles between existing stations only
when currently at a station and without an active rental. Rider station
controls shall not prohibit staff transfers. & Successful transfers
preserve maintenance state and rental records; invalid transfers leave
data unchanged.\

F-091 & Could have & **Provider placement reference.** A bicycle shall
reference exactly one existing maintenance provider if and only if its
placement is with the maintenance provider. & A missing provider for
provider placement is rejected. A provider reference for any other
placement is rejected. A bicycle never has both a station and a provider
reference.\
F-092 & Could have & **Transfer records.** Every successful station
transfer shall create an immutable transfer record with the bicycle,
source station, destination station, acting staff member, timestamp and
optional reason. & The staff actor comes from the session. The timestamp
follows F-047. The record cannot be edited or deleted operationally. A
rejected transfer creates no record.\
F-093 & Could have & **Transfer validation and atomicity.** A transfer
shall have different source and destination stations, and the source
shall equal the bicycle's current station immediately before the move.
The transfer record and the new current station shall commit together. &
Same-station and wrong-source transfers are rejected without changes. A
failure before commit leaves neither the record nor the new station.
Verify under R-004.\
:::

\*Maintenance Providers

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

F-096 & Could have & **Provider details.** Each maintenance provider
shall have a required name, optional contact email, optional contact
phone, and an active flag that defaults to active. & A blank or
whitespace-only name is rejected. A new provider is active unless stated
otherwise. Missing contact details are accepted.\
F-097 & Could have & **Provider deactivation.** Staff shall be able to
deactivate a provider. Deactivation shall not move bicycles or alter
historical jobs. & A deactivated provider cannot receive new handovers
or job assignments. Bicycles it holds keep their placement. Existing
jobs and their provider references are unchanged.\
:::

\*Fault Reports

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
F-098 & Should have & **Fault report details.** Each fault report shall
reference one bicycle and the reporting account, and store a category,
severity, description, status and report timestamp. & Categories:
brakes, tyres, drivetrain, battery, electrical, other. Severities:
minor, major, critical. Statuses: open, in_review, resolved, rejected.
Unsupported values are rejected. A new report starts as `open`
(assumption). The timestamp follows F-047.\
F-099 & Should have & **Fault submission.** Authenticated riders and
staff shall be able to submit fault reports. Staff may report on behalf
of another rider. & Unauthenticated requests are rejected. The reporting
account comes from the session. A report on an unknown bicycle is
rejected without creating data.\
F-100 & Should have & **Rental context.** A fault report may reference a
rental, which shall be for the same bicycle. A rider-submitted report
shall reference only that rider's own rental. & A rental for a different
bicycle is rejected. A rider referencing another rider's rental is
rejected. Staff-submitted reports may reference any rental of that
bicycle. A report without a rental is valid.\
F-101 & Could have & **Maintenance job link.** A fault report may
reference a maintenance job, which shall be for the same bicycle. & A
job for a different bicycle is rejected. A report without a job is
valid.\
F-102 & Could have & **Fault review and resolution.** Staff shall review
reports and move them to resolved or rejected. A resolved timestamp
shall exist if and only if the status is resolved. & `resolved_at` is
set when the status becomes resolved and absent otherwise. `resolved_at`
is not earlier than the report timestamp. Unauthorized actors cannot
change the status.\
F-103 & Should have & **Fault independence.** Submitting, assigning or
linking a fault report shall not change bicycle availability, rental
state or placement, and shall not resolve the report automatically. &
After these actions the bicycle's maintenance state and placement are
unchanged. Completing a linked job does not resolve the report.\
****************
:::

\*Maintenance Jobs and Tasks

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
F-104 & Could have & **Job creation and assignment.** Staff shall open a
maintenance job for a bicycle, with an optional provider and an optional
assigned staff member. & An assigned provider shall be active. An
unknown bicycle, provider or staff member is rejected. Opening a job
sets its status to open and records the opening time.\
F-105 & Could have & **One open job per bicycle.** A bicycle shall have
at most one open or in-progress job at any time. & A second job for a
bicycle with an open or in-progress job is rejected. Concurrent attempts
produce at most one such job (R-007). A new job is allowed after the
previous one is completed or cancelled.\
F-106 & Could have & **Job lifecycle.** A job shall be open,
in_progress, completed or cancelled. Completed and cancelled are
terminal. & A terminal job cannot be reopened or changed to another
status. Unsupported statuses are rejected.\
F-107 & Could have & **Job timestamps and closure.** A closed job
(completed or cancelled) shall have a closing time and a nonblank
resolution. An open or in-progress job shall have no closing time. &
Start and close times are not earlier than the opening time. The closing
time is not earlier than the start time. A closure without a resolution
is rejected.\
F-108 & Could have & **Maintenance tasks.** A job shall contain numbered
tasks, each with a type (inspection, repair, battery_check or test) and
a description. & Task numbers are positive and unique within their job.
A task belongs to exactly one job. Unsupported types are rejected.\
F-109 & Could have & **Task completion.** A task's outcome and
completion time shall be both present or both absent. The completion
time shall lie within the job's lifetime. & A task with only one of the
two values is rejected. A completion time before the job opened or after
it closed is rejected.\
F-110 & Could have & **Job completion rule.** A job can be completed
only when every task is completed. & Completing a job with an incomplete
task is rejected without changes. The case of a job with no tasks
follows a documented rule (to be decided).\
F-111 & Should have & **Job independence from placement.** Opening,
assigning, cancelling or completing a job shall not itself move, rent or
return the bicycle or change its maintenance state. & After each of
these operations the bicycle's placement, station and maintenance state
are unchanged. Movement and state changes occur only through
F-029--F-031.\
****************
:::

\*Bicycle Maintenance

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-028** & Must have & **Maintenance state**

Each bicycle shall have exactly one maintenance state: serviceable or
unavailable for maintenance, independent of placement and battery
eligibility. & Unsupported states are rejected. A bicycle with the
maintenance provider may be serviceable after repair, but remains
ineligible for rental because it is not at a station.\

**F-029** & Could have & **Maintenance handover**

Authorized staff shall hand over a bicycle to the maintenance provider
only from station placement without an active rental. & The operation
clears its current station, sets provider placement, and marks it
unavailable for maintenance. Station controls do not restrict handover.
An invalid source state rejects without changes. The change and audit
entry commit together under F-075; rental records are preserved.\

**F-030** & Could have & **Return from maintenance**

Authorized staff shall return a provider-held bicycle to an existing
station with an explicitly supplied valid maintenance state. & The
operation sets station placement, the destination station, and the
supplied state. A serviceable provider-held bicycle may be returned.
Station controls do not restrict the operation. Incorrect-source or
repeated transitions reject without changes. The change and audit entry
commit together under F-075; rental records are preserved.\

**F-031** & Should have & **Maintenance-state updates**

Authorized staff shall update a bicycle's maintenance state at any
placement, including during an active rental. & Updates preserve
placement, rental records, and active rentals, and commit with their
audit entry under F-075. Marking a rented bicycle unavailable does not
end the rental; it still requires a normal rider or staff-assisted
station return.\

F-094 & Could have & **Handover provider.** A maintenance handover shall
name the receiving provider, which shall be active. & A handover to an
inactive or unknown provider is rejected without changes. On success the
bicycle references that provider (F-091). Audit follows F-075.\
F-095 & Could have & **Provider reference on return.** Returning a
bicycle from maintenance shall clear its provider reference along with
setting its station and maintenance state. & After a successful return
the provider reference is absent and the station reference is set. A
repeated return is rejected under F-030.\
:::

\*Electric Bicycle Battery Management

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-032** & Must have & **Battery values**

Electric bicycle battery readings shall be integer percentages from 0 to
100 inclusive or initially missing. Regular bicycles shall not have
readings. & Fractional, nonnumeric, out-of-range values and readings for
regular bicycles are rejected. A valid electric reading may be supplied
at creation; otherwise it is missing until the first accepted update.\

**F-033** & Could have & **Battery import**

Authorized staff shall import battery readings with independent atomic
acceptance or rejection for each record and an explicit result for each
record. & Unknown bicycles, regular bicycles,
missing/fractional/nonnumeric/out-of-range values reject without
changing the previous reading. Valid records in a partially invalid
batch still apply. Duplicate bicycle records follow a documented
processing order.\

**F-034** & Won't have this stage & **Repeatable battery simulation**

The project shall provide battery-reading simulation using fixed inputs
or a fixed seed and deterministic record order. & From the same
baseline, replaying the same simulation and processing order produces
the same accepted updates, rejected records, and final readings.
Simulated records follow the same validation rules as imports.\

**F-035** & Could have & **Current battery reading**

Only the latest accepted battery percentage in processing order shall be
retained. Readings do not expire. & Each valid update replaces the
previous percentage regardless of when it was measured. Invalid updates
preserve the prior state. Operational updates cannot clear a reading to
missing. Concurrent updates have an unambiguous processing order
consistent with R-006. No battery-history log or measurement timestamp
is required.\
:::

\*Bicycle Availability

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-036** & Must have & **Availability counts**

Availability queries shall return separate regular/electric counts using
the rental-eligibility rules in F-040. & Count only serviceable bicycles
at the station without an active rental; electric bicycles also need at
least 20% battery. Rental-disabled stations show zero. Counts are
independent of the viewer, do not reserve bicycles, and do not replace
eligibility checks at rental start.\

**F-037** & Should have & **Availability consistency**

Availability queries shall use a coherent committed snapshot of bicycle
state and station controls. & A query started after a change commits
includes that change unless superseded by a later one. Overlapping
operations cannot produce a mixture of inconsistent states. Covered
changes include rentals, returns, transfers, maintenance movements/state
updates, battery updates, and station-control updates.\
:::

\*Rental Eligibility and Start

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-038** & Must have & **Rental ownership**

Each rental shall identify exactly one rider account and one specific
bicycle. & Missing/invalid references and staff accounts used as riders
are rejected.\

**F-039** & Must have & **Rider eligibility**

A rental shall start only for an authenticated active rider without an
active rental. Rider status shall be checked against current persisted
state at the trusted operation boundary, rather than copied from an
earlier login decision. & Blocked riders and riders already renting
cannot start another rental. Blocking a rider with an existing session
prevents subsequent starts under the ordering rules in R-006. Login
success does not bypass rental eligibility checks, and staff cannot
start a rental as a rider.\

**F-040** & Must have & **Bicycle eligibility**

A rental shall start only for a serviceable bicycle without an active
rental, located at a rental-enabled station. Electric bicycles shall
additionally require a reading of at least 20%. & Failure of any
condition prevents rental creation; missing battery readings prevent
electric bicycle rental.\

**F-041** & Must have & **One active rental**

Each rider and bicycle shall have at most one active rental at any time.
& Concurrent requests cannot create multiple active rentals for either.\

**F-042** & Must have & **Rental start**

Starting a rental shall record the bicycle's station immediately before
the start as its pickup station, assign a system start timestamp,
capture the pricing terms under F-053, change its placement to active
rental, and leave its end timestamp, return station, and final charge
absent. & A successful start satisfies F-039--F-041 and F-053, creates
one active rental with its pricing snapshot, records the pickup station,
and removes the bicycle's current station. All changes are atomic under
R-001.\

F-113 & Should have & **Rental immutability.** A rental's rider,
bicycle, pickup station, tariff reference and pricing snapshot shall not
change after creation. The first completion is final. & Attempts to
modify these values through operational interfaces are rejected. A
completed rental's return values cannot be overwritten (see F-080).\
:::

\*Bicycle Returns and Rental State

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-043** & Must have & **Return eligibility**

An active rental shall be returned only to an existing, return-enabled
station. Rider blocking and low/missing battery readings shall not
prevent return. Station capacity and docks are outside the agreed
project scope and shall not be stored or enforced as return constraints.
Authorized staff may perform the same return on behalf of the rider
under F-078. & A return-disabled destination rejects an active rental
return. Rider blocking, battery ineligibility, and a bicycle being
unavailable for maintenance do not prevent return. Completed-rental
retries follow F-045 and do not reapply current station eligibility
checks.\

**F-044** & Must have & **Return completion**

Completing an active rental shall record its return station,
system-assigned end timestamp, and calculated final charge under
F-054--F-055 together, set the bicycle's placement to at a station,
assign that station as its current station, and preserve its maintenance
state. & A completed rental has both return values and a final charge;
end time is not earlier than start time. Immediately after the
operation, before any later movement, its current station matches the
rental's return station. Later movements do not change this rental's
return-station reference. Payment is a separate step; no payment-service
call is required to complete a return.\

**F-045** & Should have & **Return retries**

After authorization, a request for a completed rental shall return its
original completion and stored charge when the destination matches; a
different destination shall return a conflict. & Requests identify the
rental, not merely the bicycle. Unknown rental IDs reject. Retries do
not change the rental, bicycle, payment, subsequent rentals, original
actor, or audit log; they do not recalculate charges or submit payment.
Current station eligibility and pricing are not rechecked for a
completed rental. The same rules apply to rider and staff retries,
including different authorized actors.\

**F-046** & Must have & **Rental states**

Every rental shall have a start timestamp. Its state is active exactly
when both end timestamp and return station are absent, and completed
exactly when both are present. These are the only rental states in the
agreed project scope. & Mixed return-value combinations are rejected. A
completed rental's end timestamp is not earlier than its start
timestamp. Any separately represented rental-state value must agree with
these facts.\

**F-047** & Must have & **Rental timestamps**

Rental start/end timestamps shall be assigned by a trusted server-side
component as UTC instants, using equivalent precision and ordering
semantics across implementations. & Client-supplied rental times are not
authoritative. Completed rentals cannot have an end earlier than start;
an invalid timestamp cannot commit a partial return. The component and
precision shall be documented before implementation comparison.\
:::

\*Rental Lookup, History, and Usage Statistics

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-048** & Should have & **Rider rental history**

The system shall retrieve a rider's active/completed rentals with
bicycle identifier, timestamps, stations, and rental state. & Only that
rider's rentals are returned. Active rentals have no return details; no
history produces an empty result.\

**F-049** & Must have & **Current active rental**

Riders shall be able to retrieve their own current active rental
independently of the optional full history feature, including after an
uncertain rental-start response. & The result contains the rental
identity, bicycle identifier, pickup station, and start time, or
indicates that there is no active rental. Repeated rental-start requests
remain subject to F-041 and cannot create a second active rental. This
lookup reports current state rather than replaying an earlier start
response.\

**F-050** & Won't have this stage & **Usage statistics**

The system should report completed-rental count, total/average duration,
and pickup/return station-pair counts over all completed rentals,
independently of F-048. & Exclude active rentals. Compute duration from
stored timestamps using F-047 precision; totals use integer units of
that precision, and averages round to the nearest unit with halves
rounded up. With no completed rentals, count/total are zero, average is
absent, and station-pair results are empty. Group pairs by stable
identities; sort by count descending, then pickup and return identity
using a common documented order. Verify under S-006.\
:::

\*Pricing and Rental Charges

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-051** & Won't have this stage & **Fixed pricing configuration**

Privileged setup shall configure one price per block for each bicycle
type, one common block length in positive integer seconds, and one
nonblank currency code. & Both prices are required, nonnegative exact
decimals with at most two fractional digits. Missing, negative,
nonnumeric, over-precision prices or invalid block lengths reject.
Stored money uses two fractional digits. All implementations use
equivalent configuration.\

**F-052** & Won't have this stage & **Pricing changes**

Pricing configuration shall change only during controlled privileged
setup while rental-start operations are stopped. & Operational
interfaces cannot change prices. Setup changes preserve pricing
snapshots and charges on existing rentals; only an explicit baseline
reset may replace those rental records.\

**F-053** & Won't have this stage & **Captured rental pricing**

Each rental shall capture its price per block, block length, and
currency from trusted configuration at start and retain those values
unchanged. & The snapshot commits with rental creation. Missing or
invalid configuration prevents start. Client-supplied prices are not
authoritative. Later setup changes cannot alter captured pricing or
completed charges. The displayed terms are checked under F-056--F-057.\

**F-054** & Won't have this stage & **Charge calculation**

On return, the system shall calculate charge as the captured price per
block multiplied by the number of started billing blocks. Duration is
end minus start at the precision in F-047. & Zero duration uses zero
blocks. Otherwise blocks equal ceiling(duration/block length), without
first rounding duration. With 30-minute blocks, exactly 30 minutes uses
one block, 31 minutes uses two, and one timestamp unit beyond 30 minutes
uses two. A zero price produces 0.00.\

**F-055** & Won't have this stage & **Charge precision and storage**

The system shall store the final charge atomically with return
completion using exact decimal or integer minor-unit arithmetic. &
Active rentals have no final charge. Identical timestamps and captured
pricing yield identical charges across implementations. Unsupported
numeric overflow rejects the return without partial changes. Completed
charges cannot be edited or recalculated through operational
interfaces.\

**F-056** & Won't have this stage & **Price display and acceptance**

Before rental start, the rider shall see price per block, block length,
currency, and the started-block charging rule. The start request shall
identify these displayed terms. & The trusted boundary compares
displayed terms with configuration. Stale or altered terms reject the
start and require a refreshed display before another start request. A
successful start captures the displayed terms under F-053.\

**F-057** & Won't have this stage & **Final charge display**

After return, the system shall show the stored final charge and
currency, using the same charge rules for rider and staff-assisted
returns. & The displayed charge equals the stored value. Payment results
are clearly labelled simulated and explain that no real money is
collected. No payment-card entry form is provided.\

F-112 & Should have & **Tariff reference.** Each rental shall reference
the tariff it was priced from, and that tariff's bicycle type shall
equal the rented bicycle's type. & A rental with a tariff of another
bicycle type is rejected. The reference is immutable. Later tariff
changes do not alter captured pricing (F-053).\
:::

\*Simulated Payment Processing

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-058** & Won't have this stage & **Payment-request eligibility**

An authenticated rider shall be able to request simulated payment for
their own completed rental with a positive final charge. & Unknown
rentals, another rider's rental, active rentals, and zero charges reject
without creating payment data. Ownership, amount, and currency come from
stored rental data. Staff cannot initiate payment for a rider. Payment
does not reopen the rental, move the bicycle, or restrict subsequent
rentals.\

**F-059** & Won't have this stage & **Payment creation and submission**

A payment request shall atomically create a pending payment record or
reuse the existing record. A pending payment shall be submitted to the
simulator with its stable payment reference, rental reference, amount,
and currency. & The pending record commits before submission; a database
failure before commit causes no submission. Concurrent requests use the
same record/reference. Pending requests may be retried under
F-063--F-065. Requests for an already successful or failed payment
return that stored outcome without a new submission or attempt. Payment
submission is separate from return completion.\

**F-060** & Won't have this stage & **Trusted payment confirmation**

Only the trusted simulator adapter shall apply payment outcomes, after
checking payment reference, rental reference, amount, and currency
against stored data. & Unknown references, mismatches, or
client-supplied outcome claims reject without changes. Riders and staff
cannot directly mark a payment successful or failed. The adapter is an
internal trusted boundary, not an unauthenticated user endpoint.\

**F-061** & Won't have this stage & **Payment-state transitions**

A pending payment shall become successful or failed only on a definitive
simulator confirmation. Both final states shall be terminal. & Timeouts
leave payment pending. Duplicate identical confirmations leave all data,
including timestamps, unchanged. Pending or conflicting results cannot
overwrite a terminal state. A confirmation-write failure leaves the
application pending and recoverable through F-063--F-065.\

**F-062** & Won't have this stage & **Payment records**

The system shall store at most one payment per rental, with a unique
stable payment reference, rental reference, the owning rider, amount,
currency, status, and trusted creation/update timestamps from F-047. &
Payments reference completed positive-charge rentals. Amount/currency
match the rental and are immutable; amounts use exact two-decimal
representation. Initial status is pending. Timestamps change only on
creation or actual status transition. The simulator uses the same
reference. Payment status is separate from rental state. Operational
deletion and manual status overrides reject.\

F-114 & Should have & **Payment immutability.** A payment's rental,
owning rider, amount and currency shall not change after creation. & The
values must match the completed rental's rider, final charge and
currency at creation. Later modification attempts are rejected. Only the
status and update timestamp change, under F-061.\
:::

\*Payment Recovery, Data Protection, and Status

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-063** & Won't have this stage & **Duplicate-safe simulated payment**

The simulator shall process a payment reference at most once, retain its
result until privileged reset, and return that result for repeated
identical requests. & Concurrent requests create at most one simulated
settlement. Reusing a reference with a different payload rejects.
Successful or failed application payments return their stored outcome
without a new attempt. A failed payment stays failed. No real money is
moved.\

**F-064** & Won't have this stage & **Uncertain payment recovery**

An unavailable simulator or a lost response shall leave the application
payment pending until a rider retries the same request and obtains a
definitive result. & When simulated success occurs but its response is
lost, a retry recovers that success under the original reference without
a second settlement. Recovery also works after an application
confirmation-write failure. The application reports uncertainty rather
than declaring success or failure without confirmation.\

**F-065** & Won't have this stage & **Deterministic payment scenarios**

Test/setup data shall select repeatable simulator outcomes independently
of concurrent request arrival order and consistently across
implementations. & Provide confirmed success, confirmed failure, and
success followed by a lost response. Replaying from an equivalent
baseline repeats any configured delay/failure behavior. Riders and staff
cannot select outcomes through operational interfaces.\

**F-066** & Won't have this stage & **Payment-data limits**

The application and simulated payment service shall not collect or store
payment-card numbers, verification codes, expiry dates, bank
credentials, or sensitive card authentication data. & No such fields
appear in request forms, request payloads, databases, logs, or audit
records. The payment flow uses only rental/payment references, stored
charge and currency, status, and required ownership/timestamp metadata.
No real payment provider or card-processing integration is included.\

**F-067** & Won't have this stage & **Payment-information access**

Riders shall retrieve charge, currency, and payment status for their own
rental by rental identity. Authorized staff shall retrieve the same
information by rental or rider. & The server checks authorization and
ownership under F-014--F-016. This lookup is mandatory even without
optional full rental history F-048. Unauthorized requests disclose no
payment data. Staff viewing does not permit payment initiation or
outcome overrides.\

**F-068** & Won't have this stage & **Payment-status display**

The system shall display payment information according to the rental and
payment record state, with outcomes labelled simulated. & Active rental:
no final charge and payment not applicable. Completed zero-charge
rental: 0.00 and payment not required, with no payment record. Completed
positive-charge rental without a payment record: not requested.
Otherwise display pending, successful, or failed. Display labels do not
add rental or payment-record states.\
:::

\*Administrative Audit Logging

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-069** & Won't have this stage & **Automatic audit entries**

Each successful covered administrative command that creates a record or
changes stored state shall produce exactly one audit entry
automatically. Covered actions are defined in F-071--F-072 and F-081. &
A handover changing placement and maintenance state creates one entry
containing both changes; a combined station update creates one entry
containing all changes. Failed/rejected commands, no-op updates, and
completed-return retries create no new entry.\

**F-070** & Won't have this stage & **Audit fields**

Each audit entry shall store the acting staff account identity obtained
from the authenticated server-side session, action type, affected record
type and stable identifier, a UTC timestamp from F-047, and the previous
and new values of changed fields. Entries describe the operation when it
committed; later valid operations may change the current state without
altering earlier entries. & A client-supplied staff identity cannot
alter audit attribution. Changing a station's rental-enabled control
from true to false stores both values. For creation the previous value
is absent. Reference-valued fields use stable identities, so name
changes do not change what a past entry identifies. Secrets, including
session credentials, are excluded under F-073.\

**F-071** & Won't have this stage & **Audited actions**

The system shall audit rider blocking/unblocking; maintenance
handover/return and state updates; station creation, descriptive
updates, and control changes; and staff-assisted return completion. &
The listed operations follow F-069 and F-075. Staff returns also follow
F-081. Bicycle creation, station-to-station transfers, and battery
updates do not create additional mandatory administrative audit events.\

**F-072** & Won't have this stage & **Action-specific audit values**

Audit entries shall contain the previous/new values needed to describe
the covered operation. & Rider entries include status. Maintenance
entries include maintenance state, placement, and current station,
including unchanged contextual values. Station entries include created
fields or changed attributes/controls. Each entry identifies its
affected entity and acting staff member under F-070. Staff-return fields
follow F-081.\

**F-073** & Won't have this stage & **Audit secret filtering**

The system shall exclude passwords, password hashes, tokens, and all
other authentication secrets from audit entries. & Sensitive fields are
filtered from stored previous/new values and from all other audit-entry
fields. No audit event contains authentication secrets.\

**F-074** & Won't have this stage & **Append-only audit log**

The system shall prevent any user from editing or deleting audit records
through the supported operational interfaces. & No operation to update
or delete audit records exists. Ordinary users are denied access to
audit records. Each implementation enforces append-only behavior with
its own mechanisms.\

**F-075** & Won't have this stage & **Atomic audit writes**

The system shall save each audit entry and the change it describes
together, so that either both exist or neither does. & If the audit
write fails, the change is not applied. If the change fails, no audit
entry is created. Injected failure cannot commit only one of the two.\

**F-076** & Won't have this stage & **Audit queries**

The system should let authorized staff filter the single administrative
audit log by staff member, action type, affected record, and date range.
This includes filtering maintenance actions for a particular bicycle; it
does not require a separate maintenance-history store or endpoint. &
Results are sorted newest first. Date filtering uses the stored UTC
audit timestamp, with an inclusive start and exclusive end. Users
without the staff role are denied access. A filter with no matches
returns an empty result without error.\

F-117 & Should have & **Audit detail rows.** Each audit entry shall have
at least one detail, numbered within the entry. A detail stores the
subject type and identifier, field name, and previous and new values as
JSON. & Subject references are logical and validated on write. A
creation may have an absent previous value. Unchanged contextual values
and unchanged NULLs are allowed. An entry without details is rejected.
Secrets are excluded under F-073.\
:::

\*Staff-Assisted Returns

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-077** & Won't have this stage & **Staff rental lookup**

The system shall allow authorized staff to find an active rental by
rental identifier, rider, or bicycle. & Staff can search active rentals
and see the rental identifier, rider, bicycle, pickup station, and start
time. Completed rentals are not offered as active rentals for return.
Users without the staff role cannot use the search. The search only
identifies a rental; the return operation independently validates its
current state and authorization.\

**F-078** & Won't have this stage & **Staff-assisted returns**

The system shall allow authorized staff to return an active rental on
behalf of its rider by supplying the rental identity and selecting an
existing, return-enabled station. Rider and staff returns shall use the
same completion and charging rules. & The rental is completed with the
selected station, server-assigned UTC end time, and final charge under
F-044, F-054--F-055. An invalid or return-disabled destination rejects
the active-rental return without changes. Rider blocking and low/missing
battery or maintenance unavailability do not prevent the return. Charge,
staff attribution, and the audit entry commit with completion and
bicycle placement under F-075 and R-002. Payment is not submitted as
part of this operation.\

**F-079** & Won't have this stage & **Staff return retries**

The system shall apply F-043--F-045 to both rider and staff-assisted
returns, including competing requests and retries. Final charges use
F-054--F-055. & Concurrent returns produce at most one completion and
one stored final charge. A later authorized request with the original
destination reports the original completion and charge; a different
destination reports a conflict. A retry does not repeat placement
changes, recalculate a charge, submit payment, overwrite the original
actor, or create another audit entry. These rules also apply when a
rider and staff member compete to complete the same rental.\

**F-080** & Won't have this stage & **Return attribution**

A rental shall retain its owning rider and shall store the acting staff
account identity if its first successful completion was staff-assisted.
That staff identity marks the return as staff-assisted. For an active
rental or a rider-completed rental, the returning staff identity is
absent. The charge and any later payment remain attributed to the owning
rider. & The first successful completion establishes the return
attribution. A later staff retry of a rider-completed return cannot
reclassify it as staff-assisted; a retry by a different staff member
cannot replace the original staff identity. Completed-return attribution
cannot be changed through supported interfaces.\

**F-081** & Won't have this stage & **Staff return audit**

The system shall create exactly one audit entry for each first
successful staff-assisted return. & The entry identifies the acting
staff member, rental, owning rider, bicycle, return station, UTC event
timestamp, and previous/new rental and bicycle placement values. It is
saved together with the return and staff attribution under F-075. A
failed or rejected attempt, a retry, or a rider-completed return
produces no staff-assisted completion entry. A return response lost
after commit is recovered through the retry rules without creating a
second entry.\

**F-082** & Won't have this stage & **Staff-return details**

The system should let riders retrieve whether their own completed rental
was closed by staff, together with return station, end time, final
charge, and currency. & Retrieval uses rental identity and does not
require full history F-048. Other riders' data is not disclosed. Values
agree with F-080 and F-054--F-055. Charge/payment access under
F-067--F-068 remains mandatory if this optional display is omitted.\
:::

\*Record Preservation and Stable Identities

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**F-083** & Must have & **Account preservation**

Supported operational functions shall preserve account records and their
rental references. Account deletion shall be excluded. & Blocking or
unblocking preserves the account and rental history.\

**F-084** & Must have & **Station and bicycle preservation**

Supported operational functions shall exclude station and bicycle
deletion. & Disabling operations or changing maintenance state preserves
records and references.\

**F-085** & Must have & **Immutable bicycle attributes**

Supported operational functions shall not change bicycle identifiers or
types after creation. & Attempts are rejected without modification.\

**F-086** & Must have & **Stable identities**

Accounts, stations, and rentals shall each have a stable unique
identity. Bicycle identity shall be unambiguous through its unique
immutable visible identifier or an additional stable identifier. &
Updates to descriptive attributes do not change which entity a
relationship identifies. Rental-targeted operations cannot identify a
rental solely by the bicycle's current active rental. No particular
identifier format or database key mechanism is prescribed.\

F-118 & Could have & **Provider preservation.** Supported operational
functions shall exclude maintenance provider deletion. Providers are
only deactivated. & A deletion attempt is rejected. Deactivation
preserves the record and all job references (F-097).\
:::

\*Operational Usability and Consistency

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**U-001** & Must have & **Operation feedback**

Each implementation shall clearly report success, expected business-rule
rejection, and unexpected failure through its supported interface. &
Results distinguish the three outcome types using meaningful messages or
status codes. Unexpected failures do not expose queries, credentials, or
stack traces.\

**U-002** & Should have & **Cross-implementation consistency**

Equivalent inputs and starting data shall produce equivalent business
outcomes for supported operations across the three separate database
implementations. & Equivalent scenarios yield equivalent results and
business-rule rejections. Optional rental history F-048, usage
statistics F-050, audit queries F-076, and staff-return details F-082
are each included or omitted consistently across implementations. Each
implementation runs separately; no graphical interface or runtime
database selection or switching is required.\

**U-003** & Should have & **Documented operation examples**

Each implementation shall provide runnable examples for station
availability queries, rental starts, and bicycle returns through its
supported interface. & Examples identify the required setup, inputs,
invocation steps, and expected results. Following the documented steps
from the agreed baseline successfully queries availability, starts a
rental, and returns that rental. The examples complement the setup
instructions in S-001.\
:::

\*Transaction Reliability and Concurrency

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**R-001** & Must have & **Atomic rental start**

Starting a rental shall commit all related changes, including its
pricing snapshot, or leave persisted data unchanged. & An injected
failure before commit cannot persist only the rental, only its pricing
snapshot, or only its placement change. Loss of a response after commit
does not imply rollback; the rider can retrieve their current active
rental under F-049, and repeated starts remain subject to F-041.\

**R-002** & Must have & **Atomic return**

Completing a rider or staff-assisted return shall commit all required
changes, including the final charge, or leave persisted data unchanged.
Staff-assisted completion also includes staff attribution and its
mandatory audit entry. Payment submission is a separate operation and is
not part of this transaction. & An injected failure before commit cannot
persist partial rental completion, final charge, bicycle placement,
staff attribution, or audit data. A response lost after commit does not
undo the return; an authorized retry follows F-045 and reports the
original completion and charge without additional changes. Simulator
failures cannot prevent or roll back a completed return.\

**R-003** & Should have & **Concurrent rental requests**

Concurrent rentals shall preserve the one-active-rental limits for
riders and bicycles. & Under all tested outcomes, at most one competing
rental becomes active for the same rider or bicycle. In a controlled
test with two otherwise valid competing requests, no unrelated state
changes, and no injected or infrastructure failure, exactly one request
succeeds and the other receives an expected business-rule rejection.\

**R-004** & Could have & **Atomic staff movements**

Staff transfers and maintenance handovers/returns shall commit all
related changes or leave persisted data unchanged. Covered maintenance
operations and maintenance-state updates shall commit their audit entry
with the change under F-075. & An injected failure before commit cannot
leave partial placement or maintenance changes, or a covered maintenance
change without its audit entry. A lost response after commit does not
imply rollback. A repeated handover or maintenance return from an
incorrect source state rejects under F-029--F-030 without adding an
audit entry.\

**R-005** & Could have & **Concurrent bicycle operations**

Concurrent rental and staff operations on a bicycle shall produce an
outcome consistent with a valid sequential order. & Maintenance blocking
first prevents rental. Rental first prevents transfer/handover. A
maintenance update after rental does not end it. Transfer first makes a
successful rental record the new pickup station.\

**R-006** & Could have & **Concurrent eligibility and returns**

Conflicting rider-status, station-control, battery, and return
operations shall produce outcomes consistent with a valid sequential
order. & Blocking or a low battery update before rental start prevents
it; afterward it does not end it. Disabling returns before completion
rejects the return; afterward it does not undo completion. A return
preserves maintenance updates. Concurrent returns produce at most one
completion; later requests follow F-045. Any integrity violation fails
validation independently of performance, and controlled success
workloads follow P-005--P-006.\

R-007 & Could have & **Concurrent job creation.** Concurrent requests to
open maintenance jobs for the same bicycle shall leave at most one open
or in-progress job. & In a controlled test with two otherwise valid
requests, exactly one succeeds and the other gets an expected
business-rule rejection.\
:::

\*Performance Benchmarking and Reporting

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**P-001** & Won't have this stage & **Operation timing**

The duration of a logical database operation shall be measured from
issuing its first database action to receiving its final result or
commit confirmation, including all database actions needed to perform
that operation. & Client-side output formatting and password hashing are
excluded consistently. Multi-action operations are not reported as only
their fastest or final query. Connection acquisition, retries, and
result-materialization boundaries shall be documented consistently in
the benchmark protocol.\

**P-002** & Won't have this stage & **Latency reporting**

Benchmarks shall report median, 95th-percentile, and 99th-percentile
durations separately by operation and sequential or concurrent workload.
Required operations include station availability queries, rental starts,
rental returns, and the current-active-rental lookup in F-049. Full
rental-history benchmarking shall be required only if F-048 is
implemented. & Required operations are measured separately; repetitions
are documented and sufficient for meaningful percentile reporting.\

**P-003** & Won't have this stage & **Outcome reporting**

Unexpected errors and expected business-rule rejections shall be
reported separately. Failed attempts shall not be silently omitted. &
Report attempt counts and outcomes separately for successes, expected
rejections, and unexpected errors. Report latency statistics by outcome
category where sample size permits; do not combine fast rejections with
successes into a single success-latency figure. Insufficient samples
shall be identified.\

**P-004** & Won't have this stage & **Equivalent benchmark conditions**

Implementations shall use equivalent starting data/scenarios and
documented test conditions, while allowing appropriate database-specific
models. & Record hardware, versions, models, indexes, configuration, and
workloads. Equivalent baselines shall include the same logical records
and relevant state distributions, pricing configuration, captured rental
prices, final charges, and payment states, not merely equal entity
counts. Payment validation uses equivalent deterministic simulator
scenarios, with injected delays and failure points documented. Core
rental benchmarks include required pricing/charge database work but do
not invoke the payment service.\

**P-005** & Won't have this stage & **Workload validation**

Controlled baseline workloads intended to succeed shall have zero
unexpected errors and zero unexpected business-rule rejections. & Report
every attempt and validate each operation separately. Rejection,
contention, and injected-failure workloads have predefined separate
expected outcomes. Any integrity violation independently fails
validation.\

**P-006** & Won't have this stage & **Benchmark baseline size**

The baseline shall contain 50 stations, 500 bicycles, 1,000 riders, and
10,000 rentals. & All implementations use equivalent logical records and
state distributions under P-004, not only matching entity counts.\

**P-007** & Won't have this stage & **Benchmark traceability**

Benchmark results shall identify implementation version, execution date,
environment, configuration, and workload. & Results can be traced to
their tested conditions, repetitions, and concurrency level.\
:::

\*System Setup, Reset, and Validation

::: longtable
\|C27mm\|C25mm\|L79mm\|L111mm\| **Requirementcode & **MoSCoW priority &
**Description & **Acceptance criteria\
\
**Requirementcode & **MoSCoW priority & **Description & **Acceptance
criteria\
****************

**S-001** & Must have & **Executable setup**

Each implementation shall provide setup instructions and executable
structure-creation/data-loading scripts, including staff provisioning,
fixed pricing, and deterministic payment scenarios. & Document the
authentication/session library, password-hashing settings, session
lifetime, billing units, monetary precision, and simulator behavior.
Supply initial passwords through setup inputs and persist only hashes,
not plaintext in baseline files or logs.\

**S-002** & Must have & **Baseline data integrity**

Setup shall produce a baseline satisfying all business constraints. &
Seeded rider/staff accounts can authenticate under F-006--F-007. Every
rental has captured pricing; completed rentals have the correct final
charge, and active rentals have none. Seeded payments, if any, agree
with their rentals and simulator results. No real money is moved.\

**S-003** & Won't have this stage & **Repeatable correctness checks**

The project shall provide repeatable validation of charging, simulated
payment, authentication, and authorization behavior. & Cover
F-054--F-055 charging boundaries, F-060--F-061, F-063--F-065 payment
outcomes/retries, concurrent duplicate registration, valid/invalid
login, blocked-rider access, direct permission/ownership rejection,
logout, expiry, and rejection of sessions issued by another
implementation. Expiry tests may use controlled server time or a shorter
test lifetime, but sessions cannot authorize requests at or after
expiry.\

**S-004** & Should have & **Privileged baseline reset**

Each implementation shall support a privileged reset restoring its
agreed data, pricing, and simulator state before new operations are
accepted. & Remove earlier test changes, including audit entries,
payments, simulator results/idempotency records, and
registration-created accounts. This setup operation is the exception to
operational preservation and append-only rules in F-083, F-084, F-074.
Restore equivalent logical records and selected features.\

**S-005** & Won't have this stage & **Reset isolation and sessions**

Reset shall invalidate all sessions for the implementation being reset
and isolate its simulator/session state from other implementations and
test runs. & Pre-reset credentials cannot authenticate after reset, even
when account identities are reused. Resetting one implementation does
not alter another implementation's sessions or simulator results.\

**S-006** & Won't have this stage & **Statistics consistency**

When optional F-050 is implemented, equivalent datasets shall produce
identical usage statistics across all implementations. & Compare
completed-rental counts, duration sums, rounded averages, and
station-pair counts/order using the same timestamp precision, rounding
rule, and stable-identity ordering. Include a dataset with no completed
rentals.\
:::
