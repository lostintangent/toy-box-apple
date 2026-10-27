import Testing
import ToyBoxUI

struct ChannelFolderNameTests {
    @Test func folderNamesUseTheLastComponentAndPreserveRootAndEmptyPaths() {
        #expect(ChannelFolderName.name(of: "/srv/work/toy-box") == "toy-box")
        #expect(ChannelFolderName.name(of: "/srv/work/toy-box/") == "toy-box")
        #expect(ChannelFolderName.name(of: "/") == "/")
        #expect(ChannelFolderName.name(of: "") == "")
    }
}
