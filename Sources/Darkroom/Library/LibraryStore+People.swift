import Foundation

/// People: find faces, name them, filter by person.
extension LibraryStore {
    func reloadPeople() {
        guard let catalog else { return }
        do {
            people = try catalog.people()
        } catch {
            errorMessage = error.localizedDescription
        }
        if let id = personFilter, !people.contains(where: { $0.id == id }) {
            personFilter = nil
        }
        reloadPersonPaths()
    }

    func reloadPersonPaths() {
        guard let catalog, let id = personFilter else {
            personPaths = []
            return
        }
        personPaths = (try? catalog.photoPaths(personID: id)) ?? []
    }

    /// Photos in the current folder or collection not yet searched for faces
    /// (virtual copies share their original's faces).
    var photosToScanForFaces: [Photo] {
        guard let catalog, let scanned = try? catalog.faceScannedPhotoIDs() else { return [] }
        return photos.filter { !$0.isVirtualCopy && !scanned.contains($0.id) }
    }

    /// Searches the shown photos for faces in the background (top bar shows progress).
    func findFaces() {
        guard faceTask == nil else { return }
        let items = photosToScanForFaces.map { (id: $0.id, url: $0.url) }
        guard !items.isEmpty else {
            notice = ("Find Faces", "Every photo here has already been searched for faces.")
            return
        }
        faceProgress = BatchProgress(label: "Finding faces", done: 0, total: items.count)
        faceTask = Task { @MainActor [weak self] in
            for item in items {
                if Task.isCancelled { break }
                let found = await Task.detached(priority: .utility) { FaceScanner.scan(url: item.url) }.value
                guard let self, !Task.isCancelled else { return }
                if let found {
                    do {
                        try self.catalog?.saveFaces(found, photoID: item.id)
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                }
                self.faceProgress?.done += 1
            }
            self?.faceProgress = nil
            self?.faceTask = nil
            self?.facesVersion += 1
        }
    }

    func cancelFaceScan() {
        faceTask?.cancel()
        faceTask = nil
        faceProgress = nil
        facesVersion += 1
    }

    func loadFaces() -> [FaceRecord] {
        (try? catalog?.faces()) ?? []
    }

    /// Names these faces (a new person is created for a new name).
    func nameFaces(_ faceIDs: [Int64], as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, !trimmed.isEmpty, !faceIDs.isEmpty else { return }
        do {
            let id = try catalog.person(named: trimmed)
            try catalog.assignFaces(faceIDs, to: id)
        } catch {
            errorMessage = error.localizedDescription
        }
        peopleChanged()
    }

    func unnameFaces(_ faceIDs: [Int64]) {
        guard let catalog else { return }
        do {
            try catalog.assignFaces(faceIDs, to: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
        peopleChanged()
    }

    func ignoreFaces(_ faceIDs: [Int64]) {
        guard let catalog else { return }
        do {
            try catalog.ignoreFaces(faceIDs)
        } catch {
            errorMessage = error.localizedDescription
        }
        peopleChanged()
    }

    func renamePerson(_ id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, !trimmed.isEmpty else { return }
        do {
            try catalog.renamePerson(id, to: trimmed)
        } catch {
            errorMessage = "Couldn't rename: \(error.localizedDescription)"
        }
        peopleChanged()
    }

    func deletePerson(_ id: Int64) {
        guard let catalog else { return }
        do {
            try catalog.deletePerson(id)
        } catch {
            errorMessage = error.localizedDescription
        }
        peopleChanged()
    }

    /// Shows only this person's photos (nil = everyone).
    func showPerson(_ id: Int64?) {
        personFilter = id
    }

    func peopleNames(for photo: Photo) -> [String] {
        (try? catalog?.peopleNames(path: photo.url.path)) ?? []
    }

    private func peopleChanged() {
        reloadPeople()
        facesVersion += 1
    }
}
