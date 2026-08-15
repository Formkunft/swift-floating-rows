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
	public struct Configuration {
		/// The height of each row in the stack.
		public var stackRowHeight: CGFloat
		/// Minimum descendants height for an item to be added to the stack.
		///
		/// The descendants height is the sum of the heights of all visible descendant items.
		public var minDescendantsHeight: CGFloat
		/// Called when a stack row receives a click.
		public var stackRowAction: ((_ sender: FloatingRowStack, _ item: AnyObject, _ event: NSEvent) -> Void)? = nil
		/// Called when a stack row receives a secondary click.
		public var stackRowSecondaryAction: ((_ sender: FloatingRowStack, _ item: AnyObject, _ event: NSEvent) -> Void)? = nil
		
		public init(
			stackRowHeight: CGFloat,
			minDescendantsHeight: CGFloat = 0,
			stackRowAction: ((_ sender: FloatingRowStack, _ item: AnyObject, _ event: NSEvent) -> Void)? = nil,
			stackRowSecondaryAction: ((_ sender: FloatingRowStack, _ item: AnyObject, _ event: NSEvent) -> Void)? = nil,
		) {
			precondition(stackRowHeight > 0)
			precondition(minDescendantsHeight >= 0)
			self.stackRowHeight = stackRowHeight
			self.minDescendantsHeight = minDescendantsHeight
			self.stackRowAction = stackRowAction
			self.stackRowSecondaryAction = stackRowSecondaryAction
		}
	}
}
