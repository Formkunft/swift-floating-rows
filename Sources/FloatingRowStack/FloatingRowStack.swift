//  Copyright 2026 Florian Pircher <formkunft.com>
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  	http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import AppKit

/// Renders a vertical stack of floating rows above an `NSOutlineView`.
///
/// Each stack row corresponds to an ancestor of the topmost visible outline row.
///
/// The stack is automatically updated for the following events:
/// - scrolling the scroll view enclosing the outline view
/// - resizing the scroll view
/// - changing expansion state of outline view items
/// - modifying the configuration
///
/// It is not automatically updated for data-source mutations.
/// Instead, call ``update()`` manually.
@MainActor
public final class FloatingRowStack: NSObject {
	// MARK: Configuration
	
	/// Modifying the configuration updates the stack.
	public var configuration: Configuration {
		didSet {
			self.update()
		}
	}
	/// Returns the view for a stack row.
	///
	/// Return `nil` when no stack row should be added for an item and its descendants.
	/// A `nil` result is not cached: the closure is invoked again on every stack update (including every scroll event) while the item remains an ancestor of the topmost visible row.
	public let makeRowView: (_ level: Int, _ item: AnyObject) -> NSView?
	
	// MARK: References
	
	private weak var outlineView: NSOutlineView? = nil
	private weak var scrollView: NSScrollView? = nil
	private weak var clipView: NSClipView? = nil
	
	/// Floating subview of the scroll view.
	public let containerView: NSView
	/// View containing the stack row views.
	public let contentView: NSView
	private var contentHeightConstraint: NSLayoutConstraint! = nil
	
	// MARK: State
	
	struct Row {
		let item: AnyObject
		let view: RowView
		let contentView: NSView
	}
	
	/// Rendered stack rows in lineage order.
	///
	/// Reconciled with the new lineage on each update by prefix-matching.
	private var _activeStackRows: [Row] = []
	/// Latest recorded top of the visible content area in document-view coordinates.
	///
	/// Guards against redundant updates from horizontal scrolls and width-only resize notifications.
	///
	/// Both trigger `boundsDidChange` without changing the lineage.
	private var _latestVisibleContentTop: CGFloat? = nil
	/// Setting to `true` schedules the update; subsequent sets before the run loop turns are no-ops.
	///
	/// Call ``update()`` instead for an immediate update.
	public var needsUpdate = false {
		didSet {
			guard self.needsUpdate && !oldValue else {
				return
			}
			
			DispatchQueue.main.async { [weak self] in
				guard let self else {
					return
				}
				self.needsUpdate = false
				self.update()
			}
		}
	}
	
	struct CacheEntry: Hashable {
		var item: AnyObject
		
		init(_ item: AnyObject) {
			self.item = item
		}
		
		static func == (lhs: Self, rhs: Self) -> Bool {
			lhs.item === rhs.item
		}
		
		func hash(into hasher: inout Hasher) {
			hasher.combine(ObjectIdentifier(self.item))
		}
	}
	
	/// Caches ``lastDescendantRow(of:outlineView:)`` results keyed by item identity.
	private var _lastDescendantRowCache: [CacheEntry: Int] = [:]
	
	// MARK: Init
	
	/// Returns `nil` if `outlineView` is not embedded in an `NSScrollView`.
	///
	/// - Parameter containerView: The view that is added as a floating subview to the scroll view.
	/// - Parameter contentView: The view into which the stack row views are added.
	///   When `nil`, `containerView` serves both roles; otherwise, must be a subview of `containerView`.
	public init?(
		outlineView: NSOutlineView,
		configuration: Configuration,
		containerView: NSView,
		contentView: NSView? = nil,
		makeRowView: @escaping (_ level: Int, _ item: AnyObject) -> NSView?,
	) {
		guard let scrollView = outlineView.enclosingScrollView else {
			return nil
		}
		self.outlineView = outlineView
		self.scrollView = scrollView
		self.clipView = scrollView.contentView
		self.configuration = configuration
		self.containerView = containerView
		self.contentView = contentView ?? containerView
		self.makeRowView = makeRowView
		
		super.init()
		
		self.containerView.isHidden = true
		self.containerView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.addFloatingSubview(self.containerView, for: .vertical)
		guard let superview = self.containerView.superview else {
			return nil
		}
		
		self.contentView.wantsLayer = true
		let heightConstraint = self.contentView.heightAnchor.constraint(equalToConstant: 0)
		self.contentHeightConstraint = heightConstraint
		
		NSLayoutConstraint.activate([
			self.containerView.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
			self.containerView.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
			self.containerView.topAnchor.constraint(equalTo: superview.topAnchor),
			heightConstraint,
		])
		
		scrollView.contentView.postsBoundsChangedNotifications = true
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(self.boundsDidChange(_:)),
			name: NSView.boundsDidChangeNotification,
			object: scrollView.contentView)
		
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(self.expansionStateDidChange(_:)),
			name: NSOutlineView.itemDidExpandNotification,
			object: outlineView)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(self.expansionStateDidChange(_:)),
			name: NSOutlineView.itemDidCollapseNotification,
			object: outlineView)
		
		// defer until first layout pass
		DispatchQueue.main.async { [weak self] in
			self?.update()
		}
	}
	
	@MainActor
	deinit {
		NotificationCenter.default.removeObserver(self)
		self.containerView.removeFromSuperview()
	}
	
	@objc private func expansionStateDidChange(_: Notification) {
		self.invalidateLastDescendantRowCache()
		self.needsUpdate = true
	}
	
	@objc private func boundsDidChange(_: Notification) {
		guard let clipView else {
			return
		}
		let newTop = clipView.bounds.origin.y + clipView.contentInsets.top
		guard newTop != self._latestVisibleContentTop else {
			return
		}
		self.updateAssumingSameRows()
	}
	
	// MARK: Public API
	
	/// Updates the rendered stack.
	public func update() {
		self.invalidateLastDescendantRowCache()
		self.updateAssumingSameRows()
	}
	
	private func invalidateLastDescendantRowCache() {
		self._lastDescendantRowCache.removeAll(keepingCapacity: self._lastDescendantRowCache.capacity <= 2048)
	}
	
	/// Updates the rendered stack, reusing cached last-descendant-row results.
	///
	/// Safe to call when the list of rows is unchanged (like for scroll or resize events).
	private func updateAssumingSameRows() {
		guard let outlineView, let clipView else {
			return
		}
		let snapshot = self.createSnapshot(
			outlineView: outlineView,
			clipView: clipView)
		self.applySnapshot(snapshot)
		self._latestVisibleContentTop = snapshot.visibleContentTop
	}
	
	/// Returns the stack row view for `item` if it is currently present in the stack, otherwise `nil`.
	///
	/// The returned view is a view created by ``makeRowView``.
	public func stackRowView(for item: AnyObject) -> NSView? {
		self._activeStackRows.first { $0.item === item }?.contentView
	}
	
	/// Scrolls the outline view so that `item`’s outline row appears just below its ancestor stack rows.
	///
	/// Accounts for ancestors that will not produce a stack row at the target scroll position.
	///
	/// May invoke ``makeRowView`` to probe ancestors that are not currently in the stack; views created by such probe calls are discarded.
	public func scrollToRow(for item: AnyObject) {
		guard let outlineView, let clipView, let scrollView else {
			return
		}
		let itemRow = outlineView.row(forItem: item)
		guard itemRow >= 0 else {
			return
		}
		
		// count the stack rows that will be present at the target scroll position
		let minDescendantsHeight = self.configuration.minDescendantsHeight
		var stackRowCount = 0
		
		for (level, ancestor) in self.ancestors(of: item, outlineView: outlineView).enumerated() {
			guard self.descendantsHeight(of: ancestor, outlineView: outlineView) >= minDescendantsHeight else {
				break
			}
			guard self.stackRowView(for: ancestor) != nil || self.makeRowView(level, ancestor) != nil else {
				break
			}
			stackRowCount += 1
		}
		
		let targetVisibleContentTop = outlineView.rect(ofRow: itemRow).minY - CGFloat(stackRowCount) * self.configuration.stackRowHeight
		let targetOriginY = targetVisibleContentTop - clipView.contentInsets.top
		
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.25
			clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetOriginY))
			scrollView.reflectScrolledClipView(clipView)
		}
	}
	
	// MARK: Geometry
	
	/// Ancestors of `item` ordered root-first, direct parent last.
	///
	/// Root (`nil`) excluded.
	private func ancestors(of item: Any, outlineView: NSOutlineView) -> ContiguousArray<AnyObject> {
		var ancestors: ContiguousArray<AnyObject> = []
		var subject = outlineView.parent(forItem: item)
		while let ancestor = subject as AnyObject? {
			ancestors.append(ancestor)
			subject = outlineView.parent(forItem: ancestor)
		}
		ancestors.reverse()
		return ancestors
	}
	
	/// Returns the row index of the last expanded descendant of `item`.
	///
	/// Returns the row index of `item` itself if it is collapsed; `-1` if `item` is not in the outline view.
	///
	/// Works for items whose last descendant is not currently scrolled into view.
	private func lastDescendantRow(of item: AnyObject, outlineView: NSOutlineView) -> Int {
		let itemRow = outlineView.row(forItem: item)
		guard itemRow >= 0 else {
			assertionFailure()
			return -1
		}
		
		// stage 1: recurse into subtree, picking the last child item every time
		var subject = item
		
		while outlineView.isItemExpanded(subject) {
			let childCount = outlineView.numberOfChildren(ofItem: subject)
			guard childCount > 0,
			      let lastChild = outlineView.child(childCount - 1, ofItem: subject) as AnyObject? else {
				break
			}
			subject = lastChild
		}
		
		let subjectRow = outlineView.row(forItem: subject)
		if subjectRow >= 0 {
			return subjectRow
		}
		
		// stage 2: NSOutlineView API returned -1 (no row for item): binary search for item row instead
		func _isDescendant(_ row: Int, of ancestor: AnyObject) -> Bool {
			var current: AnyObject? = outlineView.item(atRow: row) as AnyObject?
			while let c = current {
				if c === ancestor {
					return true
				}
				current = outlineView.parent(forItem: c) as AnyObject?
			}
			return false
		}
		
		var lower = itemRow
		var upper = outlineView.numberOfRows - 1
		while lower < upper {
			let mid = lower + (upper - lower + 1) / 2
			
			if _isDescendant(mid, of: item) {
				lower = mid
			}
			else {
				upper = mid - 1
			}
		}
		return lower
	}
	
	private func cachedLastDescendantRow(of item: AnyObject, outlineView: NSOutlineView) -> Int {
		if let cachedRow = self._lastDescendantRowCache[CacheEntry(item)] {
			return cachedRow
		}
		let row = self.lastDescendantRow(of: item, outlineView: outlineView)
		self._lastDescendantRowCache[CacheEntry(item)] = row
		return row
	}
	
	/// Total height of the rows of `item`’s expanded descendants.
	private func descendantsHeight(of item: AnyObject, outlineView: NSOutlineView) -> CGFloat {
		let itemRow = outlineView.row(forItem: item)
		let lastDescendantRow = self.cachedLastDescendantRow(of: item, outlineView: outlineView)
		guard itemRow >= 0, lastDescendantRow > itemRow else {
			return 0.0
		}
		return outlineView.rect(ofRow: lastDescendantRow).maxY - outlineView.rect(ofRow: itemRow).maxY
	}
	
	// MARK: Create Snapshot
	
	private func createSnapshot(
		outlineView: NSOutlineView,
		clipView: NSClipView,
	) -> Snapshot {
		let stackRowHeight = self.configuration.stackRowHeight
		let bounds = clipView.bounds
		let insets = clipView.contentInsets
		/// Top of the visible content area in document-view coordinates.
		///
		/// When scrolled to the top, `bounds.origin.y == -insets.top` => this equals 0.
		let visibleContentTop = bounds.origin.y + insets.top
		let scanX = bounds.origin.x + insets.left + 1
		
		/// Build the lineage depth-by-depth.
		///
		/// At each level, find the candidate child of the current last lineage entry by probing the row just above the scan line.
		/// A candidate is a match when its subtree has rows above the scan line.
		///
		/// The probe is clamped to within the current parent’s subtree.
		/// If the probe lands on a non-expanded item, walk backward through preceding siblings.
		var lineage: ContiguousArray<AnyObject> = []
		while true {
			let level = lineage.count
			let scanY = visibleContentTop + CGFloat(level) * stackRowHeight
			let parent = lineage.last
			
			// clamp probe to within the current parent’s subtree
			var probeY = scanY - 1.0
			
			if let parent {
				let parentLastDescendantRow = self.cachedLastDescendantRow(of: parent, outlineView: outlineView)
				if parentLastDescendantRow >= 0 {
					probeY = min(probeY, outlineView.rect(ofRow: parentLastDescendantRow).maxY - 1.0)
				}
			}
			
			// probe at scan line
			let probeRow = outlineView.row(at: CGPoint(x: scanX, y: probeY))
			var candidate: AnyObject?
			
			if probeRow >= 0, let probeItem = outlineView.item(atRow: probeRow) as AnyObject? {
				let probeAncestors = self.ancestors(of: probeItem, outlineView: outlineView)
				if probeAncestors.count == level {
					candidate = probeItem
				}
				else if probeAncestors.count > level {
					candidate = probeAncestors[level]
				}
				
				if candidate != nil && !zip(lineage, probeAncestors).allSatisfy({ $0 === $1 }) {
					// probe escaped the current parent’s subtree => discard candidate
					candidate = nil
				}
			}
			
			// if candidate is non-expanded, walk back through preceding siblings
			while let _candidate = candidate, !outlineView.isItemExpanded(_candidate) {
				let _candidateRow = outlineView.row(forItem: _candidate)
				guard _candidateRow > 0,
				      let precedingItem = outlineView.item(atRow: _candidateRow - 1) as AnyObject? else {
					// no preceding item
					candidate = nil
					break
				}
				
				let precedingItemAncestors = self.ancestors(of: precedingItem, outlineView: outlineView)
				if precedingItemAncestors.count < level
					|| !zip(lineage, precedingItemAncestors).allSatisfy({ $0 === $1 }) {
					// preceding item is not a match (and thus further preceding items cannot be either)
					candidate = nil
					break
				}
				
				/// Preceding item’s ancestor at current level.
				let subject = precedingItemAncestors.count == level
					? precedingItem
					: precedingItemAncestors[level]
				let subjectLastDescendantRow = self.cachedLastDescendantRow(of: subject, outlineView: outlineView)
				let subjectLastDescendantMaxY = subjectLastDescendantRow >= 0
					? outlineView.rect(ofRow: subjectLastDescendantRow).maxY
					: 0.0
				if subjectLastDescendantMaxY <= visibleContentTop {
					// preceding item’s ancestor at current level subtree is above visible content frame
					// (as will be the case for any further preceding items)
					candidate = nil
					break
				}
				
				candidate = subject
			}
			
			if let candidate {
				lineage.append(candidate)
				continue
			}
			else {
				// No candidate at this level; no deeper lineage entry can be added.
				break
			}
		}
		
		// compute per-stack-row layout
		let rows = lineage.enumerated().map { level, item in
			let naturalBottom = visibleContentTop + CGFloat(level + 1) * stackRowHeight
			let itemRow = outlineView.row(forItem: item)
			let lastDescendantRow = self.cachedLastDescendantRow(of: item, outlineView: outlineView)
			let lastDescendantMaxY: CGFloat = lastDescendantRow >= 0
				? outlineView.rect(ofRow: lastDescendantRow).maxY
				: naturalBottom
			let effectiveBottom = min(naturalBottom, lastDescendantMaxY)
			let itemMaxY: CGFloat = itemRow >= 0 ? outlineView.rect(ofRow: itemRow).maxY : naturalBottom
			let descendantsHeight: CGFloat = lastDescendantRow > itemRow && itemRow >= 0
				? lastDescendantMaxY - itemMaxY
				: 0.0
			
			return Snapshot.Row(
				item: item,
				level: level,
				clippingDistance: naturalBottom - effectiveBottom,
				descendantsHeight: descendantsHeight)
		}
		
		return Snapshot(
			rows: rows,
			visibleContentTop: visibleContentTop,
			stackRowHeight: stackRowHeight)
	}
	
	// MARK: Apply Snapshot
	
	private func applySnapshot(_ snapshot: Snapshot) {
		let stackRowHeight = snapshot.stackRowHeight
		let containerWidth = self.contentView.bounds.width
		let minDescendantsHeight = self.configuration.minDescendantsHeight
		
		let stackRowCutoff = snapshot.rows.firstIndex { $0.descendantsHeight < minDescendantsHeight } ?? snapshot.rows.endIndex
		let clippingRowCutoff = if let index = snapshot.rows.firstIndex(where: { $0.clippingDistance > 0 }) {
			// exclude a fully clipped row instead of rendering it with zero height
			snapshot.rows[index].clippingDistance < stackRowHeight
				? snapshot.rows.index(after: index)
				: index
		}
		else {
			snapshot.rows.endIndex
		}
		let effectiveRows = snapshot.rows[..<min(stackRowCutoff, clippingRowCutoff)]
		
		// maintain the matching prefix of stack row views
		var maintainedRowCount = 0
		while maintainedRowCount < self._activeStackRows.count && maintainedRowCount < effectiveRows.count &&
			self._activeStackRows[maintainedRowCount].item === effectiveRows[maintainedRowCount].item {
			maintainedRowCount += 1
		}
		
		// remove stack row views past the matching prefix
		while self._activeStackRows.count > maintainedRowCount {
			let dropped = self._activeStackRows.removeLast()
			dropped.view.removeFromSuperview()
		}
		
		// create stack row views for new lineage entries
		for row in effectiveRows[maintainedRowCount...] {
			guard let content = self.makeRowView(row.level, row.item) else {
				// client decided to cut stack short
				break
			}
			
			content.translatesAutoresizingMaskIntoConstraints = true
			content.autoresizingMask = .width
			
			let stackRowView = RowView()
			stackRowView.translatesAutoresizingMaskIntoConstraints = true
			stackRowView.autoresizingMask = .width
			
			let item = row.item
			stackRowView.clickHandler = { [weak self] event in
				guard let self else {
					return
				}
				self.configuration.stackRowAction?(self, item, event)
			}
			stackRowView.secondaryClickHandler = { [weak self] event in
				guard let self else {
					return
				}
				self.configuration.stackRowSecondaryAction?(self, item, event)
			}
			stackRowView.addSubview(content)
			self.contentView.addSubview(stackRowView)
			self._activeStackRows.append(Row(item: row.item, view: stackRowView, contentView: content))
		}
		
		// apply layout
		let renderedRows = effectiveRows.prefix(self._activeStackRows.count)
		let stackRowCount = renderedRows.count
		let containerHeight = if let lastRow = renderedRows.last {
			CGFloat(stackRowCount - 1) * stackRowHeight + max(0.0, stackRowHeight - lastRow.clippingDistance)
		}
		else {
			0.0
		}
		let contentBoundsMinY = self.contentView.bounds.minY
		let contentViewIsFlipped = self.contentView.isFlipped
		
		for rowIndex in 0 ..< self._activeStackRows.count {
			let row = effectiveRows[rowIndex]
			let entry = self._activeStackRows[rowIndex]
			let topOffset = CGFloat(row.level) * stackRowHeight
			let rowOriginY = contentViewIsFlipped
				? contentBoundsMinY + topOffset
				: contentBoundsMinY + containerHeight - topOffset - stackRowHeight
			
			let rowFrame = CGRect(
				x: 0,
				y: rowOriginY,
				width: containerWidth,
				height: stackRowHeight)
			if entry.view.frame != rowFrame {
				entry.view.frame = rowFrame
			}
			
			let contentFrame = CGRect(
				x: 0,
				y: -row.clippingDistance,
				width: containerWidth,
				height: stackRowHeight)
			if entry.contentView.frame != contentFrame {
				entry.contentView.frame = contentFrame
			}
		}
		
		if self.contentHeightConstraint.constant != containerHeight {
			self.contentHeightConstraint.constant = containerHeight
		}
		
		if stackRowCount == 0 {
			if !self.containerView.isHidden {
				self.containerView.isHidden = true
			}
		}
		else {
			if self.containerView.isHidden {
				self.containerView.isHidden = false
			}
		}
	}
}
