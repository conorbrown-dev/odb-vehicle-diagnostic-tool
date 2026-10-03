# VIN-correct ABS replacement evidence

Updated 2026-10-03. This path does not use the installed module's configuration as the factory reference. All vehicle writes, sessions, security access and hydraulic routines remain disabled.

## Factory record acquisition

Use the already known vehicle VIN, verify it against the vehicle plate, and retrieve its complete original download from https://www.motorcraftservice.com/AsBuilt. The live portal currently redirects to FordServiceInfo login; retrieval is pending the operator signing in. No factory record has been downloaded or authenticated for this VIN yet. Retain the original download locally without editing, alongside retrieval date and source. Absence of an ABS entry must be reported explicitly; never manufacture blocks from a different car or equate a CAN address with a configuration-write address.

Ford's [Module Programming guide](https://www.fordservicecontent.com/ford_content/catalog/motorcraft/FMP_User_Guide.pdf) provides a Module Build Data database route when original-module configuration cannot be retrieved. This is not evidence that another ECU holds a complete ABS backup, nor a wire-level procedure for this replacement.

## Parts evidence and limits

- Installed engineering label: BE5C-2C219-AA. [AutoECMs listing](https://www.autoecmstore.com/products/be5c-2c219-aa) identifies a 2011–2012 Fusion 3.5L application. This is supplier evidence, not a Ford VIN-based compatibility determination.
- Replacement engineering label: AE5C-2C219-FE. [Go-Parts interchange listing](https://www.go-parts.com/hl-product.php?sku=591-02022-1002456033) includes this label in interchange 591-02022, covering 2010–2012 Fusion 2.5L VIN A FWD and 3.0L FWD. This supports a candidate match, not verified compatibility for the actual unit/VIN. Marketplace fitment tables conflict in breadth and must not override VIN-specific evidence.

Before accepting replacement fitment, establish the VIN-correct Ford service part number and supersession/interchange to the actual engineering label. If the hydraulic assembly is also being replaced, verify its label/application separately. Distinguish labels from electronically reported assembly/software identities. A compatible-looking housing or ability to communicate proves neither fitment nor firmware suitability.

## Offline workflow required after retrieval

Inspect the actual factory file format before implementing a parser. Preserve raw data and provenance, verify its embedded VIN against the supplied reference, distinguish missing ABS data from an empty configuration, and keep imported records separate from ECU-read backups. The current GUI text importer requires an ECU backup and accepts only address/hex text; it is not yet a factory .ab/XML import workflow. Do not attach factory records to a donor backup as if read from that ECU.

Only after factory data and hardware compatibility are established should research proceed to the exact target-specific PMI/configuration procedure, including required initialization and readback. Owning an As-Built file is not authorization or sufficient technical evidence to implement/transmit writes. No new vehicle request was sent for this research path.

## Corrected factory download and offline CLI

The corrected user-supplied download matches the prior vehicle-capture VIN and passes the VIN check digit. It contains six BCE records labeled 760-01-01 through 760-06-01, plus node 760 E610 `BE5C-14C228-CA` and E611 `BE5C-2D053-CB`. Its CCC-not-found warning remains attached; it is not treated as missing populated ABS data. The earlier mistyped VIN download reported missing PCM/BCE and is not a usable reference.

The new `factory-abs` CLI command accepts the observed XML format and saves an unchanged original, source hash, block groups, raw node identifiers and source warnings without opening a transport. Reject VIN mismatch/bad check digit, missing/duplicate ABS data, malformed XML/hex and DTD/entity documents. No checksum bytes are stripped or recalculated and no configuration is presented as ECU-read or programming-ready. Public searches did not establish an authoritative match between these exact factory identifiers and replacement label AE5C-2C219-FE. That compatibility and the target-specific PMI procedure remain open; imported factory data alone does not justify a vehicle write or another installed-module VIN probe.
