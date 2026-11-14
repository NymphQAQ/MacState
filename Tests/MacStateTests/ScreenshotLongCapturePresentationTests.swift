import AppKit
import Testing
@testable import MacState

@Suite(.serialized) @MainActor
struct ScreenshotLongCapturePresentationTests {
    @Test func findsTargetBehindMacStateWithoutSelectingPopovers() {
        let selection = CGRect(x: 140, y: 190, width: 440, height: 360)
        // Quartz space: selection y = 900 - (190 + 360) = 350.
        let windows = [
            ScreenshotLongWindowCandidate(pid: 10, frame: CGRect(x: 120, y: 330, width: 480, height: 420), layer: 0),
            ScreenshotLongWindowCandidate(pid: 22, frame: CGRect(x: 140, y: 350, width: 100, height: 80), layer: 0),
            ScreenshotLongWindowCandidate(pid: 23, frame: CGRect(x: 110, y: 310, width: 540, height: 540), layer: 1),
            ScreenshotLongWindowCandidate(pid: 45, frame: CGRect(x: 100, y: 300, width: 700, height: 500), layer: 0)
        ]
        #expect(ScreenshotLongTargetLocator.targetPID(under: selection, primaryScreenTop: 900, ownPID: 10, windows: windows) == 45)
        #expect(ScreenshotLongTargetLocator.targetPID(under: selection, primaryScreenTop: 900, ownPID: 45, windows: windows) == 10)
        #expect(ScreenshotLongTargetLocator.targetPID(under: .zero, primaryScreenTop: 900, ownPID: 10, windows: windows) == nil)
    }

    @Test func resolvesTargetAcrossDisplayAbovePrimary() {
        let selection=CGRect(x: 120, y: 1040, width: 400, height: 240)
        let windows=[
            ScreenshotLongWindowCandidate(pid: 101, frame: CGRect(x: 100, y: -420, width: 500, height: 320), layer: 0),
            ScreenshotLongWindowCandidate(pid: 102, frame: CGRect(x: 100, y: 0, width: 500, height: 320), layer: 0)
        ]
        #expect(ScreenshotLongTargetLocator.targetPID(under:selection,primaryScreenTop:900,ownPID:500,windows:windows)==101)
    }

    @Test func onlyMacStatePanelIsHiddenAndRestoredOnce() {
        // Model the two apps' visibility. No AppKit window is shown by tests.
        var panelVisible=true,otherAppVisible=true
        var resolved=0,activated=0,restored=0,hidden=0
        let selection=CGRect(x:10,y:12,width:180,height:150)
        let presentation=ScreenshotLongCapturePresentation(
            isPanelVisible:{ panelVisible },
            hidePanel:{ hidden+=1;panelVisible=false },
            restorePanelWindow:{ restored+=1;panelVisible=true },
            targetApplication:{ rect in
                #expect(rect==selection)
                resolved+=1
                return nil
            },
            activateTarget:{_ in activated+=1})
        presentation.begin(selection:selection)
        presentation.begin(selection:selection)
        #expect(presentation.isCapturing)
        #expect(!panelVisible && otherAppVisible)
        #expect(resolved==1 && hidden==1 && activated==0)
        presentation.end()
        presentation.end()
        #expect(!presentation.isCapturing)
        #expect(panelVisible && otherAppVisible)
        #expect(restored==1)
        _ = otherAppVisible
    }

    @Test func initiallyHiddenMacStatePanelRemainsHidden() {
        var panelVisible=false
        var restored=0,hidden=0
        let presentation=ScreenshotLongCapturePresentation(
            isPanelVisible:{ panelVisible },
            hidePanel:{ hidden+=1;panelVisible=false },
            restorePanelWindow:{ restored+=1;panelVisible=true },
            targetApplication:{_ in nil},
            activateTarget:{_ in Issue.record("A nil target must not be activated")})
        presentation.begin(selection:CGRect(x:12,y:20,width:100,height:100))
        presentation.end()
        #expect(!panelVisible && restored==0 && hidden==0)
        #expect(!presentation.isCapturing)
    }
}
