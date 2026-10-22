# unity-bridge

Unity has no official DAT support. The pattern: write an Android Kotlin plugin (AAR) that wraps `mwdat-*` and pass frames and events to Unity C#.
Reference: Photon's "Meta Wearables Camera Streaming" sample (Unity 6.3, DAT 1.0; needs a Photon login and has no stated license, so read it but don't copy it).
Only worth doing if the end goal is 3D/AR-ish content on the phone or a networked experience.
Feasibility and bridge design: FEASIBILITY.md.
