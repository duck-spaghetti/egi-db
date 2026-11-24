# EGI canonical information

The terms below describe how EGI retains information from multiple sources while
maintaining one canonical directory of real-world services and related information.

## Language

**Canonical entity**:
A real-world entity represented by EGI's maintained directory information. Several
source descriptions can refer to the same entity.
_Avoid_: Source record, imported row

**Source record**:
One distinguishable record supplied by a source, describing one or more real-world
entities. Its source identity is separate from EGI's canonical identity.
_Avoid_: Canonical entity

**Source assertion**:
A value or relationship claimed by a source about an entity. Different sources
may make conflicting assertions about the same attribute.
_Avoid_: Verified fact, canonical value

**Normalized record**:
A derived interpretation of source information, expressed in comparable domain
terms while retaining its connection to the original source description.
_Avoid_: Canonical record

**Entity resolution**:
The process of deciding whether source descriptions refer to the same real-world
entity and how they relate to maintained canonical information.
_Avoid_: String matching, unconditional deduplication

**Canonical value**:
A value selected for EGI's maintained representation of an entity. The source
assertions supporting or contradicting it remain distinguishable.
_Avoid_: Original value, only known value

**Offline distribution**:
A read-only representation of selected canonical information for use without
network access. It derives from the authoritative dataset and has no independent
editorial authority.
_Avoid_: Second authoritative database, bidirectional replica

**Operating schedule**:
The declared times at which a particular service or activity operates, including
any known limits on when that declaration applies.
_Avoid_: Contact availability, service lifecycle status

**Contact availability**:
The times at which a contact channel can be used to reach its intended recipient.
_Avoid_: Service operating hours

**Map territory**:
A geographic selection used to organize and present EGI directory information.
The same real-world entity may be included in several overlapping map territories.
_Avoid_: Service coverage area, residence requirement

**Service coverage area**:
The geographic reach declared for a service, independently of the map territories
in which EGI presents it or any separately stated geographic access requirement.
_Avoid_: Map territory

**Service**:
A distinct offer at a delivery place or area, with its own identity, operating
information and revision history. Similar offers at different places are distinct
services; organizations and classifications can connect them. Non-geographic offers
such as telephone services need not have a physical location.
_Avoid_: Organization, facility, universal multi-location offering

**Location**:
A physical delivery place that may host multiple services, including services from
different organizations and categories. A host facility's operator is not necessarily
the organization delivering each hosted service.
_Avoid_: Service, mandatory single provider

**Compound phone contact**:
A contact expression that denotes multiple telephone numbers, written as complete
numbers or through a terminal abbreviation. Its original wording is distinct from
the individual numbers it may denote.
_Avoid_: Single telephone number, automatically callable contact

**Protected phone identity**:
An individual telephone number whose publication is restricted by an editorial
decision, including when it appears within a compound contact. Recognizing that
identity for protection does not establish permission to publish it.
_Avoid_: Public contact, verified contact, automatically normalized contact

**Contact protection register**:
The maintained record of editorial restrictions on contact publication, including
unresolved telephone restrictions and their explicit release decisions. Active
restrictions persist independently of source updates or restored content.
_Avoid_: Source contact list, current revision visibility, public contact directory
