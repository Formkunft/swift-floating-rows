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

import Foundation

extension FloatingRowStack {
	/// Describes the stack layout at a moment in time.
	struct Snapshot {
		struct Row {
			let item: AnyObject
			let level: Int
			var clippingDistance: CGFloat
			let descendantsHeight: CGFloat
		}
		
		let rows: [Row]
		/// Top of the visible content area in document-view coordinates.
		let visibleContentTop: CGFloat
		let stackRowHeight: CGFloat
	}
}
