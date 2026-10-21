//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// Locale aliases shared by the data generators that read CLDR XML
// (update-list-format-data, update-relative-date-format-data). Each
// generator compiles this file alongside its own impl.

// The list of locale aliases below is hand-maintained.
// It's used to handle deprecated identifiers such as `iw` → `he` and minimized
// identifiers such as `zh_HK` → `zh_Hant_HK`, so that we are able to retrieve
// the correct patterns.
// For example, with these aliases we are able to correctly resolve
// `zh_HK` → `zh_Hant_HK` → `及`, instead of the incorrect `zh_HK` → `zh` → `和`.
// This list was originally based on the `%%ALIAS` entries in
// `icu/icu4c/source/data/locales/*.txt`, which were in turn derived from a
// hard-coded list in `icu/tools/cldr/cldr-to-icu/config.xml`.
let localeAliases: [String: String] = [
    "ars": "ar_SA",
    "az_AZ": "az_Latn_AZ",
    "bs_BA": "bs_Latn_BA",
    "en_NH": "en_VU",
    "en_RH": "en_ZW",
    "ff_CM": "ff_Latn_CM",
    "ff_GN": "ff_Latn_GN",
    "ff_MR": "ff_Latn_MR",
    "ff_SN": "ff_Latn_SN",
    "in": "id",
    "in_ID": "id_ID",
    "iw": "he",
    "iw_IL": "he_IL",
    "ks_IN": "ks_Arab_IN",
    "ku_SY": "ku_Latn_SY",
    "kxv_IN": "kxv_Latn_IN",
    "mni_IN": "mni_Beng_IN",
    "mo": "ro",
    "no_NO": "no",
    "no_NO_NY": "nn_NO",
    "pa_IN": "pa_Guru_IN",
    "pa_PK": "pa_Arab_PK",
    "sat_IN": "sat_Olck_IN",
    "sd_IN": "sd_Deva_IN",
    "sd_PK": "sd_Arab_PK",
    "sh": "sr_Latn",
    "sh_BA": "sr_Latn_BA",
    "sh_CS": "sr_Latn_RS",
    "sh_YU": "sr_Latn_RS",
    "shi_MA": "shi_Tfng_MA",
    "sr_BA": "sr_Cyrl_BA",
    "sr_CS": "sr_RS",
    "sr_Cyrl_CS": "sr_Cyrl_RS",
    "sr_Cyrl_YU": "sr_Cyrl_RS",
    "sr_Latn_CS": "sr_Latn_RS",
    "sr_Latn_YU": "sr_Latn_RS",
    "sr_ME": "sr_Latn_ME",
    "sr_RS": "sr_Cyrl_RS",
    "sr_XK": "sr_Cyrl_XK",
    "sr_YU": "sr_RS",
    "su_ID": "su_Latn_ID",
    "tl": "fil",
    "tl_PH": "fil_PH",
    "uz_AF": "uz_Arab_AF",
    "uz_UZ": "uz_Latn_UZ",
    "vai_LR": "vai_Vaii_LR",
    "yue_CN": "yue_Hans_CN",
    "yue_HK": "yue_Hant_HK",
    "zh_CN": "zh_Hans_CN",
    "zh_HK": "zh_Hant_HK",
    "zh_MO": "zh_Hant_MO",
    "zh_SG": "zh_Hans_SG",
    "zh_TW": "zh_Hant_TW",
]
