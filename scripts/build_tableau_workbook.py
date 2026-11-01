"""Generate dashboard/delivery_dashboard_v3.twb, a Tableau workbook, from the dashboard extracts.

Why generated: a .twb is XML, so building it from a script makes the dashboard reproducible.
It reads the CSVs live, using the absolute path of this checkout, so run it again after moving
the folder. The format follows a workbook saved by Tableau 2026.3. Colours and spacing are left at
Tableau's defaults, and can be changed by hand after opening.
"""
import csv
import random
import string
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import quoteattr

ROOT = Path(__file__).resolve().parent.parent
TABLES = ROOT / "outputs" / "tables"
OUT = ROOT / "dashboard" / "delivery_dashboard_v3.twb"

random.seed(20261101)  # Same ids on every run, so a rebuild gives the same file.
DASHBOARD = "Delivery Performance"
CAPTION = ("Late = delivered date after promised date. Defect = proxy from cancellations and low reviews. "
           "Carrier = pickup-to-customer stage, not a named company. Causes are a counterfactual attribution. "
           "Filters do not apply to the seller table. "
           "Data: Brazilian E-Commerce Public Dataset by Olist, CC BY-NC-SA 4.0.")


def token(length=28):
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=length))


def simple_id():
    return f"<simple-id uuid='{{{str(uuid.UUID(int=random.getrandbits(128), version=4)).upper()}}}' />"


FACT = "federated." + token()
SELLER = "federated." + token()

# Field: (caption, formula, default format). Rates are always a ratio of two SUMs.
PCT, DAY = "p0.0%", "n#,##0.0;-#,##0.0"
CALCS = {
    "Calculation_1000000000000001": ("Breach Rate", "SUM([late]) / SUM([delivered])", PCT),
    "Calculation_1000000000000002": ("Promise Accuracy", "1 - SUM([late]) / SUM([delivered])", PCT),
    "Calculation_1000000000000003": ("Avg Delivery Days", "SUM([sum_delivery_days]) / SUM([delivered])", DAY),
    "Calculation_1000000000000004": ("Defect Proxy", "SUM([defects]) / SUM([orders])", PCT),
    "Calculation_1000000000000006": ("Carrier Share", "SUM([late_carrier]) / SUM([late])", PCT),
    "Calculation_1000000000000007": ("Seller Share", "SUM([late_seller]) / SUM([late])", PCT),
    "Calculation_1000000000000008": ("Promise Share", "SUM([late_promise]) / SUM([late])", PCT),
    "Calculation_1000000000000009": ("Multiple Share", "SUM([late_multiple]) / SUM([late])", PCT),
}
BY_CAPTION = {v[0]: k for k, v in CALCS.items()}
COUNT = "n#,##0"
SELLER_FORMATS = {"breach_rate": PCT, "breach_ci_low": PCT, "breach_ci_high": PCT, "dispatch_miss_rate": PCT,
                  "defect_rate": PCT, "avg_days_late": DAY, "excess_late_orders": DAY, "worst_rank": COUNT, "delivered": COUNT}
# Short labels, because Tableau builds filter titles and table headers from these.
CAPTIONS = {"purchase_month": "Purchase", "customer_state": "State", "seller_short_id": "Seller", "seller_state": "State",
            "worst_rank": "Rank", "breach_rate": "Breach", "breach_ci_low": "Wilson Low", "dispatch_miss_rate": "Dispatch Miss",
            "avg_days_late": "Days Late", "defect_rate": "Defect", "excess_late_orders": "Excess Late"}
REMOTE_TYPES = {"date": 133, "string": 129, "integer": 20, "real": 5}


def column_types(path):
    """Infer each CSV column's type by reading every row."""
    with path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    types = {}
    for name in rows[0]:
        values = [r[name] for r in rows if r[name] != ""]
        if name == "purchase_month":
            types[name] = "date"
        elif all(v.lstrip("-").isdigit() for v in values):
            types[name] = "integer"
        elif all(v.replace(".", "", 1).replace("-", "").replace("e", "").isdigit() for v in values):
            types[name] = "real"
        else:
            types[name] = "string"
    return types


def caption(name):
    return CAPTIONS.get(name, name.replace("_", " ").title())


def datasource_xml(ds, label, types, calcs, formats):
    """One CSV data source, in the structure Tableau itself saves."""
    conn, csv_name = "textscan." + token(), f"{label}.csv"
    object_id = f"{csv_name.replace('.csv', '')}.csv_{uuid.UUID(int=random.getrandbits(128)).hex.upper()}"
    cols = "".join(f"<column datatype='{t}' name='{n}' ordinal='{i}' />" for i, (n, t) in enumerate(types.items()))
    relation = (f"<relation connection='{conn}' name='{csv_name}' table='[{label}#csv]' type='table'>"
                f"<columns character-set='UTF-8' header='yes' locale='en_IN' separator=','>{cols}</columns></relation>")
    records = []
    for i, (n, t) in enumerate(types.items()):
        aggregation = {"date": "Year", "string": "Count"}.get(t, "Sum")
        extra = "<scale>1</scale><width>1073741823</width>" if t == "string" else ""
        collation = "<collation flag='0' name='LEN_RGB' />" if t == "string" else ""
        records.append(
            f"<metadata-record class='column'><remote-name>{n}</remote-name><remote-type>{REMOTE_TYPES[t]}</remote-type>"
            f"<local-name>[{n}]</local-name><parent-name>[{csv_name}]</parent-name><remote-alias>{n}</remote-alias>"
            f"<ordinal>{i}</ordinal><local-type>{t}</local-type><aggregation>{aggregation}</aggregation>{extra}"
            f"<contains-null>true</contains-null>{collation}<object-id>[{object_id}]</object-id></metadata-record>")
    columns = [f"<column caption='{csv_name}' datatype='table' name='[__tableau_internal_object_id__].[{object_id}]' "
               "role='measure' type='quantitative' />"]
    columns += column_defs(types, calcs, formats)
    return (
        f"<datasource caption='{label}' inline='true' name='{ds}' version='18.1'><connection class='federated'>"
        f"<named-connections><named-connection caption='{label}' name='{conn}'>"
        f"<connection class='textscan' directory={quoteattr(TABLES.as_posix())} filename='{csv_name}' password='' server='' />"
        f"</named-connection></named-connections>{relation}<metadata-records>{''.join(records)}</metadata-records></connection>"
        f"<aliases enabled='yes' />{''.join(columns)}"
        "<layout dim-ordering='alphabetic' measure-ordering='alphabetic' show-structure='true' />"
        # The map must search Brazil. This machine's default country would misplace the states.
        "<semantic-values><semantic-value key='[Country].[Name]' value='&quot;Brazil&quot;' /></semantic-values>"
        f"<object-graph><objects><object caption='{csv_name}' id='{object_id}'><properties context=''>{relation}"
        "</properties></object></objects></object-graph></datasource>")


def column_defs(types, calcs, formats):
    defs = []
    for n, t in types.items():
        role = "dimension" if t in ("string", "date") else "measure"
        kind = {"string": "nominal", "date": "ordinal"}.get(t, "quantitative")
        semantic = " semantic-role='[State].[Name]'" if n == "state_name" else ""
        fmt = f" default-format={quoteattr(formats[n])}" if n in formats else ""
        defs.append(f"<column caption='{caption(n)}' datatype='{t}'{fmt} name='[{n}]' role='{role}'{semantic} type='{kind}' />")
    for name, (label, formula, fmt) in calcs.items():
        defs.append(f"<column caption='{label}' datatype='real' default-format={quoteattr(fmt)} name='[{name}]' "
                    f"role='measure' type='quantitative'><calculation class='tableau' formula={quoteattr(formula)} /></column>")
    return defs


def instance(pill):
    """Build a column-instance from a pill name such as sum:late:qk or usr:Calculation_x:qk."""
    derivation, field, kind = pill.split(":")
    words = {"sum": "Sum", "none": "None", "usr": "User", "tmn": "Month-Trunc"}
    long_kind = {"qk": "quantitative", "nk": "nominal", "ok": "ordinal"}[kind]
    return (f"<column-instance column='[{field}]' derivation='{words[derivation]}' name='[{pill}]' pivot='key' "
            f"type='{long_kind}' />")


MONTH, STATE, CATEGORY = "tmn:purchase_month:ok", "none:customer_state:nk", "none:category:nk"
SHARED = [(MONTH, 1), (STATE, 2), (CATEGORY, 3)]


def field_of(pill):
    return pill.split(":")[1]


def worksheet(name, ds, label, all_types, calcs, formats, pills, shelves, mark, encodings, *,
              filters="", sort="", slices=(), shared=True, is_map=False, label_style=False, custom_label="", sheet_style=""):
    """One sheet. Every pill it uses is declared in its datasource-dependencies."""
    used = set(pills) | ({p for p, _ in SHARED} if shared else set())
    fields = {field_of(p) for p in used}
    wanted_types = {n: t for n, t in all_types.items() if n in fields}
    wanted_calcs = {n: v for n, v in calcs.items() if n in fields}
    deps = "".join(column_defs(wanted_types, wanted_calcs, formats)) + "".join(instance(p) for p in sorted(used))
    shared_filters = ""
    all_slices = list(slices)
    if shared:
        for pill, group in SHARED:
            shared_filters += (f"<filter class='categorical' column='[{ds}].[{pill}]' filter-group='{group}'>"
                               f"<groupfilter function='level-members' level='[{pill}]' user:ui-enumeration='all' "
                               "user:ui-marker='enumerate' /></filter>")
            all_slices.append(f"[{ds}].[{pill}]")
    slice_xml = "<slices>" + "".join(f"<column>{c}</column>" for c in all_slices) + "</slices>" if all_slices else ""
    style = "<style><style-rule element='mark'><format attr='mark-labels-show' value='true' /></style-rule></style>" if label_style else ""
    rows, cols = shelves
    rows_xml = f"<rows>{rows}</rows>" if rows else "<rows />"
    cols_xml = f"<cols>{cols}</cols>" if cols else "<cols />"
    return (
        f"<worksheet name='{name}'><layout-options><title><formatted-text><run fontsize='11'>{name}</run></formatted-text></title></layout-options>"
        f"<table><view><datasources><datasource caption='{label}' name='{ds}' /></datasources>"
        f"{'<mapsources><mapsource name=' + chr(39) + 'Tableau' + chr(39) + ' /></mapsources>' if is_map else ''}"
        f"<datasource-dependencies datasource='{ds}'>{deps}</datasource-dependencies>"
        f"{filters}{shared_filters}{sort}{slice_xml}<aggregation value='true' /></view>{sheet_style or '<style />'}"
        "<panes><pane selection-relaxation-option='selection-relaxation-allow'><view><breakdown value='auto' /></view>"
        f"<mark class='{mark}' /><encodings>{encodings}</encodings>{custom_label}{style}</pane></panes>"
        f"{rows_xml}{cols_xml}</table>{simple_id()}</worksheet>")


def measure_filter(ds, pills):
    """Keep only the chosen measures in Measure Names, in the chosen order."""
    members = "".join(f"<groupfilter function='member' level='[:Measure Names]' member='&quot;[{ds}].[{p}]&quot;' />" for p in pills)
    buckets = "".join(f"<bucket>&quot;[{ds}].[{p}]&quot;</bucket>" for p in pills)
    return (f"<filter class='categorical' column='[{ds}].[:Measure Names]'><groupfilter function='union' user:op='manual'>{members}"
            f"</groupfilter></filter><manual-sort column='[{ds}].[:Measure Names]' direction='ASC'><dictionary>{buckets}</dictionary></manual-sort>")


def usr(label):
    return f"usr:{BY_CAPTION[label]}:qk"


def fact_sheets(types):
    def sheet(*args, **kwargs):
        name, pills, shelves, mark, encodings = args
        return worksheet(name, FACT, "dash_fact", types, CALCS, {}, pills, shelves, mark, encodings, **kwargs)

    def tile(name, pill):
        label = f"<customized-label><formatted-text><run fontsize='20'><![CDATA[<[{FACT}].[{pill}]>]]></run></formatted-text></customized-label>"
        return sheet(name, [pill], ("", ""), "Automatic", f"<text column='[{FACT}].[{pill}]' />", label_style=True, custom_label=label)

    breach = usr("Breach Rate")
    month = "tmn:purchase_month:qk"
    share_axis = ("<style><style-rule element='axis'>"
                  f"<format attr='title' class='0' field='[{FACT}].[Multiple Values]' scope='cols' value='Share of late orders' />"
                  f"<format attr='text-format' field='[{FACT}].[Multiple Values]' value='p0%' /></style-rule>"
                  f"<style-rule element='cell'><format attr='text-format' field='[{FACT}].[Multiple Values]' value='p0.0%' /></style-rule></style>")
    shares = [usr(x) for x in ["Carrier Share", "Seller Share", "Promise Share", "Multiple Share"]]
    return [
        tile("Orders", "sum:orders:qk"),
        tile("Promise Accuracy", usr("Promise Accuracy")),
        tile("Avg Delivery Days", usr("Avg Delivery Days")),
        tile("Defect Proxy", usr("Defect Proxy")),
        # The rolling rate stays in rpt_kpi_monthly: as a table calculation here it repeated the monthly values.
        sheet("Monthly Breach Rate", [breach, month], (f"[{FACT}].[{breach}]", f"[{FACT}].[{month}]"), "Line", ""),
        sheet("Breach Rate by State", [breach, "sum:delivered:qk", "sum:late:qk", "none:state_name:nk"],
              (f"[{FACT}].[Latitude (generated)]", f"[{FACT}].[Longitude (generated)]"), "Multipolygon",
              f"<color column='[{FACT}].[{breach}]' /><lod column='[{FACT}].[none:state_name:nk]' />"
              f"<tooltip column='[{FACT}].[sum:delivered:qk]' /><tooltip column='[{FACT}].[sum:late:qk]' />"
              f"<geometry column='[{FACT}].[Geometry (generated)]' />", is_map=True),
        # All states rather than a top 10: a top-N filter would go empty when one small state is selected.
        sheet("Cause of Late Orders by State", shares + [STATE, "sum:late:qk"], (f"[{FACT}].[{STATE}]", f"[{FACT}].[Multiple Values]"), "Bar",
              f"<color column='[{FACT}].[:Measure Names]' />", filters=measure_filter(FACT, shares),
              sort=f"<computed-sort column='[{FACT}].[{STATE}]' direction='DESC' using='[{FACT}].[sum:late:qk]' />",
              slices=[f"[{FACT}].[:Measure Names]"], sheet_style=share_axis),
    ]


def seller_sheet(types):
    measures = ["sum:worst_rank:qk", "sum:delivered:qk", "sum:breach_rate:qk", "sum:breach_ci_low:qk", "sum:dispatch_miss_rate:qk",
                "sum:avg_days_late:qk", "sum:defect_rate:qk", "sum:excess_late_orders:qk"]
    seller_id, state = "none:seller_short_id:nk", "none:seller_state:nk"
    limit = (f"<filter class='quantitative' column='[{SELLER}].[sum:worst_rank:qk]' included-values='in-range'>"
             "<min>1</min><max>15</max></filter>")
    return worksheet("Worst Sellers by Wilson Low", SELLER, "dash_seller_scorecard", types, {}, SELLER_FORMATS, measures + [seller_id, state],
                     (f"([{SELLER}].[{seller_id}] * [{SELLER}].[{state}])", f"[{SELLER}].[:Measure Names]"), "Automatic",
                     f"<text column='[{SELLER}].[Multiple Values]' />",
                     filters=limit + measure_filter(SELLER, measures),
                     sort=f"<computed-sort column='[{SELLER}].[{seller_id}]' direction='ASC' using='[{SELLER}].[sum:worst_rank:qk]' />",
                     slices=[f"[{SELLER}].[sum:worst_rank:qk]", f"[{SELLER}].[:Measure Names]"], shared=False, label_style=True)


class Zones:
    """Lay zones out in Tableau's 100,000 x 100,000 coordinate space."""

    def __init__(self):
        self.next_id = 1

    def zone(self, x, y, w, h, attrs, children=""):
        zid, self.next_id = self.next_id, self.next_id + 1
        return f"<zone {attrs} h='{h}' id='{zid}' w='{w}' x='{x}' y='{y}'>{children}</zone>"

    def row(self, y, h, items, widths=None):
        """Lay out zone-attribute strings across a row. Widths default to equal shares and sum to 100000."""
        widths = widths or [100000 // len(items)] * len(items)
        inner, x = "", 0
        for attrs, width in zip(items, widths):
            inner += self.zone(x, y, width, h, attrs)
            x += width
        return self.zone(0, y, 100000, h, "param='horz' type-v2='layout-flow'", inner)


def dashboard_xml(types):
    z = Zones()
    trend = "Monthly Breach Rate"
    filters = [f"mode='checkdropdown' name='{trend}' param='[{FACT}].[{p}]' type-v2='filter'" for p, _ in SHARED]
    sheet_zone = lambda n: f"name='{n}'"
    def legend(sheet, param):
        return f"name='{sheet}' pane-specification-id='0' param='[{FACT}].[{param}]' show-title='false' type-v2='color'"

    causes, state_map = "Cause of Late Orders by State", "Breach Rate by State"
    # Row heights: title, tiles, filters, trend and map, causes and sellers, caption.
    content = (
        z.zone(0, 0, 100000, 4500, "type-v2='title'")
        + z.row(4500, 13000, [sheet_zone(n) for n in ["Orders", "Promise Accuracy", "Avg Delivery Days", "Defect Proxy"]])
        + z.row(17500, 6500, filters)
        + z.row(24000, 31000, [sheet_zone(trend), sheet_zone(state_map)])
        + z.row(55000, 39000, [sheet_zone(causes), legend(causes, ":Measure Names"), sheet_zone("Worst Sellers by Wilson Low")],
                [36000, 11000, 53000])
        + z.zone(0, 94000, 100000, 6000, "type-v2='text'",
                 f"<formatted-text><run fontsize='9'>{CAPTION}</run></formatted-text>")
    )
    flow = z.zone(0, 0, 100000, 100000, "param='vert' type-v2='layout-flow'", content)
    root = z.zone(0, 0, 100000, 100000, "type-v2='layout-basic'", flow)
    pills = [p for p, _ in SHARED]
    wanted = {n: t for n, t in types.items() if n in {field_of(p) for p in pills}}
    deps = "".join(column_defs(wanted, {}, {})) + "".join(instance(p) for p in pills)
    return (
        f"<dashboard name='{DASHBOARD}'><layout-options><title><formatted-text><run>E-commerce Delivery Performance &amp; Seller Analytics</run>"
        "</formatted-text></title></layout-options><style />"
        "<size maxheight='900' maxwidth='1200' minheight='900' minwidth='1200' sizing-mode='fixed' />"
        f"<datasources><datasource caption='dash_fact' name='{FACT}' /></datasources>"
        f"<datasource-dependencies datasource='{FACT}'>{deps}</datasource-dependencies>"
        f"<zones>{root}</zones>{simple_id()}</dashboard>")


def windows_xml(names):
    cards = ("<cards><edge name='left'><strip size='160'><card type='pages' /><card type='filters' /><card type='marks' /></strip></edge>"
             "<edge name='top'><strip size='2147483647'><card type='columns' /></strip><strip size='2147483647'><card type='rows' /></strip>"
             "<strip size='31'><card type='title' /></strip></edge></cards>")
    sheets = "".join(f"<window class='worksheet' name='{n}'>{cards}{simple_id()}</window>" for n in names)
    views = "".join(f"<viewpoint name='{n}'><zoom type='entire-view' /></viewpoint>" for n in names)
    return (f"<windows source-height='30'>{sheets}<window class='dashboard' maximized='true' name='{DASHBOARD}'>"
            f"<viewpoints>{views}</viewpoints><active id='-1' />{simple_id()}</window></windows>")


def main():
    fact_types = column_types(TABLES / "dash_fact.csv")
    seller_types = column_types(TABLES / "dash_seller_scorecard.csv")
    sheets = fact_sheets(fact_types) + [seller_sheet(seller_types)]
    names = [s.split("name='", 1)[1].split("'", 1)[0] for s in sheets]
    xml = (
        "<?xml version='1.0' encoding='utf-8' ?>\n\n<!-- build 20263.26.1022.1645 -->\n"
        "<workbook original-version='18.1' source-build='2026.3.0 (20263.26.1022.1645)' source-platform='win' version='18.1' "
        "xmlns:user='http://www.tableausoftware.com/xml/user'>"
        "<document-format-change-manifest><AnimationOnByDefault /><MarkAnimation /><ObjectModelEncapsulateLegacy /><ObjectModelTableType />"
        "<SchemaViewerObjectModel /><SheetIdentifierTracking /><SortTagCleanup /><WindowsPersistSimpleIdentifiers /></document-format-change-manifest>"
        "<preferences><preference name='ui.encoding.shelf.height' value='24' /><preference name='ui.shelf.height' value='26' /></preferences>"
        "<datasources>"
        + datasource_xml(FACT, "dash_fact", fact_types, CALCS, {})
        + datasource_xml(SELLER, "dash_seller_scorecard", seller_types, {}, SELLER_FORMATS)
        + "</datasources><worksheets>" + "".join(sheets) + "</worksheets>"
        + "<dashboards>" + dashboard_xml(fact_types) + "</dashboards>"
        + windows_xml(names) + "</workbook>\n")
    ET.fromstring(xml.encode("utf-8"))  # Fails loudly if the XML is not well formed.
    OUT.write_text(xml, encoding="utf-8")
    print(f"Wrote {OUT} with {len(names)} sheets and 1 dashboard")


if __name__ == "__main__":
    main()
