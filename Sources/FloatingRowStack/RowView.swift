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

extension FloatingRowStack {
	/// Clipping container for one stack row.
	final class RowView: NSView {
		var clickHandler: ((NSEvent) -> Void)? = nil
		var secondaryClickHandler: ((NSEvent) -> Void)? = nil
		
		override var isFlipped: Bool { true }
		
		override init(frame frameRect: NSRect) {
			super.init(frame: frameRect)
			self.wantsLayer = true
			self.layer?.masksToBounds = true
		}
		
		@available(*, unavailable)
		required init?(coder: NSCoder) { fatalError() }
		
		override func mouseDown(with event: NSEvent) {
			self.clickHandler?(event)
		}
		
		override func rightMouseDown(with event: NSEvent) {
			self.secondaryClickHandler?(event)
		}
	}
}
