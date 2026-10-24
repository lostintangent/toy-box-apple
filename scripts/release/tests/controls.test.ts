import { expect, test } from "bun:test";
import { validateControlExports, validateControlMetadata } from "../widget-extension.ts";

function metadata() {
    return {
        actions: {
            OpenToyBoxControlIntent: {
                fullyQualifiedTypeName: "ToyBoxControlIntents.OpenToyBoxControlIntent",
                openAppWhenRun: true, supportedModes: 2, isDiscoverable: false,
                parameters: [{
                    name: "target", isOptional: false,
                    valueType: { linkEnumeration: { wrapper: { identifier: "ToyBoxControlDestination" } } },
                }],
            },
        },
        enums: [{
            identifier: "ToyBoxControlDestination",
            fullyQualifiedTypeName: "ToyBoxControlIntents.ToyBoxControlDestination",
            cases: [{ identifier: "quickSend" }, { identifier: "needsYou" }],
        }],
    };
}

test("controls require extracted shared foreground metadata, not an empty successful processor output", () => {
    expect(() => validateControlMetadata(JSON.stringify(metadata()))).not.toThrow();
    for (const value of [null, {}, { actions: {}, enums: [] }]) {
        expect(() => validateControlMetadata(JSON.stringify(value))).toThrow("Control metadata");
    }
    expect(() => validateControlMetadata("{")).toThrow();
});

test("controls reject background-only, unrelated, optional or incomplete destinations", () => {
    const changes = [
        (value: ReturnType<typeof metadata>) => { value.actions.OpenToyBoxControlIntent.openAppWhenRun = false; },
        (value: ReturnType<typeof metadata>) => { value.actions.OpenToyBoxControlIntent.supportedModes = 1; },
        (value: ReturnType<typeof metadata>) => { value.actions.OpenToyBoxControlIntent.isDiscoverable = true; },
        (value: ReturnType<typeof metadata>) => { value.actions.OpenToyBoxControlIntent.fullyQualifiedTypeName = "Other.Intent"; },
        (value: ReturnType<typeof metadata>) => { value.actions.OpenToyBoxControlIntent.parameters[0].isOptional = true; },
        (value: ReturnType<typeof metadata>) => { value.actions.OpenToyBoxControlIntent.parameters = []; },
        (value: ReturnType<typeof metadata>) => {
            value.actions.OpenToyBoxControlIntent.parameters[0].valueType.linkEnumeration.wrapper.identifier = "Other";
        },
        (value: ReturnType<typeof metadata>) => { value.enums[0].cases.pop(); },
        (value: ReturnType<typeof metadata>) => { value.enums[0].cases.push({ identifier: "sendAutomatically" }); },
        (value: ReturnType<typeof metadata>) => { value.enums[0].cases[1].identifier = "quickSend"; },
    ];
    for (const change of changes) {
        const value = metadata();
        change(value);
        expect(() => validateControlMetadata(JSON.stringify(value))).toThrow("Control metadata");
    }
});

test("native validation requires compiled controls, their bundle and the shared action", () => {
    const names = [
        "ToyBoxControlIntents.OpenToyBoxControlIntent : AppIntents.AppIntent",
        "ToyBoxWidget.ToyBoxWidgets : SwiftUI.WidgetBundle",
        "ToyBoxWidget.QuickSendControl : SwiftUI.ControlWidget",
        "ToyBoxWidget.NeedsYouControl : SwiftUI.ControlWidget",
    ];
    const lines = names.map(name => `0000 S protocol conformance descriptor for ${name} in ToyBoxWidget`);
    expect(() => validateControlExports(lines.join("\n"), true)).not.toThrow();
    expect(() => validateControlExports(lines.join("\n").replaceAll(" S ", " s "), true)).not.toThrow();
    expect(() => validateControlExports(lines[0], false)).not.toThrow();
    for (const missing of lines) {
        expect(() => validateControlExports(lines.filter(line => line !== missing).join("\n"), true))
            .toThrow("Missing compiled control conformance");
    }
    expect(() => validateControlExports("OpenToyBoxControlIntent QuickSendControl NeedsYouControl", true)).toThrow();
});
