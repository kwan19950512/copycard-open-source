import Foundation
import Combine

@MainActor final class WorkspaceModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var left: BrowserModel
    @Published var right: BrowserModel?
    @Published var activeRight = false
    var activeBrowser: BrowserModel { activeRight ? (right ?? left) : left }
    init(left: BrowserModel) { self.left = left }
}
@MainActor final class WindowRegistry: ObservableObject {
    @Published var workspaces: [WorkspaceModel] = []
    func create(location: URL) -> WorkspaceModel {
        let workspace = WorkspaceModel(left: BrowserModel(location: location)); workspaces.append(workspace); return workspace
    }
    func merge(_ first: WorkspaceModel, _ second: WorkspaceModel) {
        guard first.id != second.id, first.right == nil, second.right == nil else { return }
        first.right = second.left; workspaces.removeAll { $0.id == second.id }
    }
    func split(_ workspace: WorkspaceModel) -> WorkspaceModel? {
        guard let right = workspace.right else { return nil }
        let other = WorkspaceModel(left: right); workspace.right = nil; workspaces.append(other); return other
    }
}
