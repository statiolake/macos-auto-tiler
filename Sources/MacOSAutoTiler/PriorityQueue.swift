import Foundation

struct PriorityQueue<Element> {
    private var elements: [Element] = []
    private let areSorted: (Element, Element) -> Bool

    init(sort: @escaping (Element, Element) -> Bool) {
        self.areSorted = sort
    }

    var isEmpty: Bool {
        elements.isEmpty
    }

    mutating func enqueue(_ element: Element) {
        elements.append(element)
        siftUp(from: elements.count - 1)
    }

    mutating func dequeue() -> Element? {
        guard !elements.isEmpty else {
            return nil
        }
        if elements.count == 1 {
            return elements.removeLast()
        }
        elements.swapAt(0, elements.count - 1)
        let element = elements.removeLast()
        siftDown(from: 0)
        return element
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        var parent = (child - 1) / 2
        while child > 0, areSorted(elements[child], elements[parent]) {
            elements.swapAt(child, parent)
            child = parent
            parent = (child - 1) / 2
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = (2 * parent) + 1
            let right = left + 1
            var candidate = parent

            if left < elements.count, areSorted(elements[left], elements[candidate]) {
                candidate = left
            }
            if right < elements.count, areSorted(elements[right], elements[candidate]) {
                candidate = right
            }
            if candidate == parent {
                return
            }
            elements.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
