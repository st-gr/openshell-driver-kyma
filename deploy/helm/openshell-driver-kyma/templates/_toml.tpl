# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
{{/*
Render the gateway TOML from a dict, as upstream's chart renders gatewayConfig.
Ported from upstream OpenShell's chart (deploy/helm/openshell/templates/_toml.tpl
at the pinned tag): the value helpers verbatim, and its table emitter as
openshell-driver-kyma.gatewayToml. Upstream's comment follows.

The chart deliberately treats the top-level keys as TOML table names. Nested
maps are TOML inline tables, and maps in arrays are inline-table array items.
This keeps the YAML-to-TOML boundary generic: adding a non-secret gateway
field must not require a Helm template change.
*/}}

{{/* Render a TOML key. Bare keys keep ordinary output readable. */}}
{{- define "openshell-driver-kyma.toml.key" -}}
{{- $key := . | toString -}}
{{- if regexMatch "^[A-Za-z0-9_-]+$" $key -}}
{{- $key -}}
{{- else -}}
{{- $key | quote -}}
{{- end -}}
{{- end -}}

{{/* Render a scalar. Strings are serialized literally. */}}
{{- define "openshell-driver-kyma.toml.scalar" -}}
{{- $value := index . 1 -}}
{{- if kindIs "string" $value -}}
{{- if regexMatch "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----" $value -}}
{{- fail "gatewayConfig must not contain an inline private key; provide it through a Secret-backed file mount" -}}
{{- end -}}
{{- if regexMatch "^[A-Za-z][A-Za-z0-9+.-]*://[^/@[:space:]]*@" $value -}}
{{- fail "gatewayConfig must not contain inline URL credentials; provide them through a Secret-backed environment variable, file, or volume" -}}
{{- end -}}
{{- $value | quote -}}
{{- else if or
    (kindIs "bool" $value)
    (kindIs "int" $value)
    (kindIs "int8" $value)
    (kindIs "int16" $value)
    (kindIs "int32" $value)
    (kindIs "int64" $value)
    (kindIs "uint" $value)
    (kindIs "uint8" $value)
    (kindIs "uint16" $value)
    (kindIs "uint32" $value)
    (kindIs "uint64" $value)
    (kindIs "float32" $value)
    (kindIs "float64" $value) -}}
{{- $value | toJson -}}
{{- else -}}
{{- fail (printf "gatewayConfig values must be strings, booleans, numbers, maps, or arrays; got %s" (kindOf $value)) -}}
{{- end -}}
{{- end -}}

{{/* Render a TOML inline table, omitting YAML null values. */}}
{{- define "openshell-driver-kyma.toml.inlineTable" -}}
{{- $root := index . 0 -}}
{{- $table := index . 1 -}}
{{- $entries := list -}}
{{- range $key := keys $table | sortAlpha -}}
{{- $value := get $table $key -}}
{{- if ne $value nil -}}
{{- if eq $key "database_url" -}}
{{- fail "gatewayConfig must not contain database_url; provide database credentials through the chart's Secret-backed OPENSHELL_DB_URL environment variable" -}}
{{- end -}}
{{- $entry := printf "%s = %s" (include "openshell-driver-kyma.toml.key" $key) (include "openshell-driver-kyma.toml.value" (list $root $value)) -}}
{{- $entries = append $entries $entry -}}
{{- end -}}
{{- end -}}
{{- printf "{ %s }" (join ", " $entries) -}}
{{- end -}}

{{/* Render an array. Maps become TOML inline-table entries. */}}
{{- define "openshell-driver-kyma.toml.array" -}}
{{- $root := index . 0 -}}
{{- $array := index . 1 -}}
{{- $entries := list -}}
{{- range $value := $array -}}
{{- if eq $value nil -}}
{{- fail "gatewayConfig arrays cannot contain null values" -}}
{{- end -}}
{{- $entries = append $entries (include "openshell-driver-kyma.toml.value" (list $root $value)) -}}
{{- end -}}
{{- printf "[%s]" (join ", " $entries) -}}
{{- end -}}

{{/* Render any supported YAML value as TOML. */}}
{{- define "openshell-driver-kyma.toml.value" -}}
{{- $root := index . 0 -}}
{{- $value := index . 1 -}}
{{- if kindIs "map" $value -}}
{{- include "openshell-driver-kyma.toml.inlineTable" (list $root $value) -}}
{{- else if kindIs "slice" $value -}}
{{- include "openshell-driver-kyma.toml.array" (list $root $value) -}}
{{- else -}}
{{- include "openshell-driver-kyma.toml.scalar" (list $root $value) -}}
{{- end -}}
{{- end -}}

{{/* Render the dict (dict "config" $dict) as deterministic TOML tables: tables
sorted by name, keys sorted within a table. Top-level lists represent TOML arrays
of tables and preserve their order. */}}
{{- define "openshell-driver-kyma.gatewayToml" -}}
{{- $root := . -}}
{{- $config := .config -}}
{{/* A nested YAML map and its dotted top-level table would serialize to
conflicting TOML definitions. Fail before rendering an invalid ConfigMap. */}}
{{- range $tableName := keys $config | sortAlpha -}}
{{- $fields := get $config $tableName -}}
{{- if kindIs "map" $fields -}}
{{- range $fieldName := keys $fields -}}
{{- $nestedTableName := printf "%s.%s" $tableName $fieldName -}}
{{- if hasKey $config $nestedTableName -}}
{{- fail (printf "gatewayConfig defines %q both as a nested map and a dotted top-level table; use only the dotted top-level key" $nestedTableName) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $tableName := keys $config | sortAlpha -}}
{{- $fields := get $config $tableName -}}
{{- if ne $fields nil -}}
{{- if and (not (kindIs "map" $fields)) (not (kindIs "slice" $fields)) -}}
{{- fail (printf "gatewayConfig table %q must be a map, got %s" $tableName (kindOf $fields)) -}}
{{- end -}}
{{- $header := list -}}
{{- $segments := splitList "." $tableName -}}
{{- range $index, $segment := $segments -}}
{{- if eq $segment "" -}}
{{- fail (printf "gatewayConfig table %q contains an empty TOML key segment" $tableName) -}}
{{- end -}}
{{- $header = append $header (include "openshell-driver-kyma.toml.key" $segment) -}}
{{- end -}}
{{- if kindIs "map" $fields -}}
{{ printf "[%s]\n" (join "." $header) }}
{{- range $fieldName := keys $fields | sortAlpha }}
{{- $value := get $fields $fieldName -}}
{{- if ne $value nil }}
{{- if eq $fieldName "database_url" -}}
{{- fail "gatewayConfig must not contain database_url; provide database credentials through the chart's Secret-backed OPENSHELL_DB_URL environment variable" -}}
{{- end -}}
{{ printf "%s = %s\n" (include "openshell-driver-kyma.toml.key" $fieldName) (include "openshell-driver-kyma.toml.value" (list $root $value)) }}
{{- end }}
{{- end }}
{{- else -}}
{{- range $index, $entry := $fields -}}
{{- if not (kindIs "map" $entry) -}}
{{- fail (printf "gatewayConfig array-of-tables %q entry %d must be a map, got %s" $tableName $index (kindOf $entry)) -}}
{{- end -}}
{{ printf "[[%s]]\n" (join "." $header) }}
{{- range $fieldName := keys $entry | sortAlpha }}
{{- $value := get $entry $fieldName -}}
{{- if ne $value nil }}
{{- if eq $fieldName "database_url" -}}
{{- fail "gatewayConfig must not contain database_url; provide database credentials through the chart's Secret-backed OPENSHELL_DB_URL environment variable" -}}
{{- end -}}
{{ printf "%s = %s\n" (include "openshell-driver-kyma.toml.key" $fieldName) (include "openshell-driver-kyma.toml.value" (list $root $value)) }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
