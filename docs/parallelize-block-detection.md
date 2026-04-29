# Feature update: replacing the crop and detect for the blocks

## Step 1: swap in & out
Use the updated BoxDetector within the frame processor.
Get the block detection part out of the inorder function, put it into the parallel execution part
Inorder part:
```swift
// This is problematic
var blockDetections: [BlockDetection] = []
for await blockDetection in blockDetector.perforAll(on: frame, in: blockROIs) {
    var allBlocks = blockDetection
    if var objects = allBlocks.objects {
        objects.removeAll { block in
            isInvalidBlock(block, allBlocks.ROI, basedOn: hands.first, handedness) ||
            block.confidence < FrameProcessingThresholds.blockConfidenceThreshold
        }
        allBlocks.objects = objects
    }
    blockDetections.append(allBlocks)
}
let nextState = currentState.transition(by: hands, currentBox, blockDetections)
```

Parallel execution part:
```swift
// Add the block detection here
func startProcessing(stream: AsyncStream<(CIImage, CMTime)>) {
        mainTask = Task { [weak self] in
            
            let maxConcurrentTasks = FrameProcessingThresholds.maxConcurrentTasks
            await withTaskGroup(of: Void.self) { group in
                var activeTasks = 0
                
                for await (image, timestamp) in stream {
                    guard let self, !Task.isCancelled else { break }
                    
                    if activeTasks >= maxConcurrentTasks {
                        await group.next()
                        activeTasks -= 1
                    }

                    if await self.countingBlocks {
                        let index = await self.currentIndex
                        await self.incrementIdx()
                        
                        group.addTask {
                            var partialResults = FrameResult(presentationTime: timestamp, state: .free, boxDetection: await self.currentBox)
                            let currentHandedness = await self.handedness
                            
                            partialResults.hands = await self.detectnFilterHands(in: image, currentHandedness)
                            self.partialResult(partialResults)
                            await self.resultContinuation?.yield((index, partialResults, image))
                        }
                    } else ...
```

Also update the view to show all the bounding boxes for the blocks. 
Don't worry about updating the state transition logic with the new block detection results. 
Just ignore the state transition by blocks, I want to visualize the block detection before next move.